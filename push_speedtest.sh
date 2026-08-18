#!/bin/bash

# =========================================================
# push_speedtest.sh
# Raspberry Pi OS / Debian Trixie
#
# ARM64  -> Ookla speedtest
# ARMHF  -> Debian speedtest-cli
# =========================================================

set -o pipefail

# --- Script directory / ISP configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISP_CFG="${SCRIPT_DIR}/isp.cfg"

if [[ ! -f "$ISP_CFG" ]]; then
    echo "❌ FATAL: ISP configuration file not found: $ISP_CFG"
    exit 1
fi

# =========================================================
# Detect architecture / Speedtest implementation
# =========================================================

SPEEDTEST_TYPE=""

detect_speedtest() {

    local ARCH
    ARCH=$(dpkg --print-architecture 2>/dev/null)

    echo "🖥️ Architecture: ${ARCH:-unknown}"

    # -----------------------------------------------------
    # ARMHF / 32-bit Raspberry Pi
    # -----------------------------------------------------

    if [[ "$ARCH" == "armhf" ]]; then

        if command -v speedtest-cli >/dev/null 2>&1; then

            SPEEDTEST_TYPE="speedtest-cli"

            echo "✅ Using Debian speedtest-cli: $(command -v speedtest-cli)"

            return 0
        fi

        echo "📦 Installing Debian speedtest-cli..."

        sudo apt update || {
            echo "❌ FATAL: apt update failed"
            return 1
        }

        sudo apt install -y speedtest-cli || {
            echo "❌ FATAL: Unable to install speedtest-cli"
            return 1
        }

        if ! command -v speedtest-cli >/dev/null 2>&1; then
            echo "❌ FATAL: speedtest-cli installation failed"
            return 1
        fi

        SPEEDTEST_TYPE="speedtest-cli"

        echo "✅ speedtest-cli installed: $(command -v speedtest-cli)"

        return 0
    fi

    # -----------------------------------------------------
    # ARM64 / Ookla
    # -----------------------------------------------------

    if [[ "$ARCH" == "arm64" ]]; then

        if command -v speedtest >/dev/null 2>&1; then

            SPEEDTEST_TYPE="ookla"

            echo "✅ Using Ookla speedtest: $(command -v speedtest)"

            return 0
        fi

        echo "❌ FATAL: Ookla speedtest is not installed on ARM64."
        echo "   The script will NOT add the obsolete packagecloud repository."

        return 1
    fi

    # -----------------------------------------------------
    # Unknown architecture
    # -----------------------------------------------------

    echo "❌ FATAL: Unsupported architecture: ${ARCH:-unknown}"

    return 1
}

detect_speedtest || exit 1

# =========================================================
# Configuration
# =========================================================

INFLUX_HOST="influxdb"

PASS=$(sudo cat /etc/speedtest/influxdb_pass) || {
    echo "❌ FATAL: Cannot read InfluxDB password"
    exit 1
}

TS=$(date +%s%N)
HOSTNAME=$(hostname)

# =========================================================
# Wi-Fi SSID detection
# =========================================================

detect_wifi_ssid() {

    local SSID

    if command -v iw >/dev/null 2>&1; then

        SSID=$(iw dev wlan0 link 2>/dev/null |
            awk -F': ' '/SSID:/ {print $2; exit}')

        if [[ -n "$SSID" ]]; then
            echo "📶 Wi-Fi SSID detected: $SSID" >&2
            echo "$SSID"
            return 0
        fi
    fi

    return 1
}

# =========================================================
# Detect public IP
# =========================================================

detect_public_ip() {

    local PUBLIC_IP

    PUBLIC_IP=$(curl -4 -s \
        --connect-timeout 5 \
        --max-time 10 \
        https://api.ipify.org)

    if [[ -z "$PUBLIC_IP" ]]; then
        echo "❌ Unable to detect public IPv4 address" >&2
        return 1
    fi

    echo "$PUBLIC_IP"
}

# =========================================================
# Cache detected SSID
# =========================================================

update_cached_ssid() {

    local SSID="$1"
    local TMP_CFG="${ISP_CFG}.tmp"

    grep -vE '^[[:space:]]*#?[[:space:]]*DETECTED_SSID=' \
        "$ISP_CFG" > "$TMP_CFG"

    {
        echo "# DETECTED_SSID=$SSID"
        cat "$TMP_CFG"
    } > "${TMP_CFG}.new"

    mv "${TMP_CFG}.new" "$ISP_CFG"
    rm -f "$TMP_CFG"

    echo "💾 Cached SSID updated: $SSID" >&2
}

# =========================================================
# Detect ISP / SSID from public IP
# =========================================================

detect_box() {

    local PUBLIC_IP="$1"
    local SSID FQDN LOCAL_CFG_IP RESOLVED_IP
    local CACHED_SSID=""
    local LOCAL_IPS

    # Get all IPv4 addresses assigned to this device
    LOCAL_IPS=$(ip -4 addr show scope global |
        awk '/inet / {print $2}' |
        cut -d/ -f1)

    echo "🖧 Local device IPs: $(echo "$LOCAL_IPS" | tr '\n' ' ')" >&2

    # -----------------------------------------------------
    # Read cached SSID
    # -----------------------------------------------------

    CACHED_SSID=$(awk -F= '
        /^[[:space:]]*#?[[:space:]]*DETECTED_SSID=/ {
            sub(/^[[:space:]]*#?[[:space:]]*DETECTED_SSID=/, "", $0)
            gsub(/[[:space:]]/, "", $0)
            print $0
            exit
        }
    ' "$ISP_CFG")

    if [[ -n "$CACHED_SSID" ]]; then

        echo "⚡ Cached SSID: $CACHED_SSID" >&2

        while IFS='=' read -r SSID FQDN LOCAL_CFG_IP; do

            [[ "$SSID" != "$CACHED_SSID" ]] && continue

            SSID="$(echo "$SSID" | xargs)"
            FQDN="$(echo "$FQDN" | xargs)"
            LOCAL_CFG_IP="$(echo "$LOCAL_CFG_IP" | xargs)"

            [[ -z "$FQDN" || -z "$LOCAL_CFG_IP" ]] && continue

            echo "🔎 Fast check: $SSID → $FQDN=$LOCAL_CFG_IP" >&2

            RESOLVED_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null |
                awk 'NR==1 {print $1}')

            if [[ -n "$RESOLVED_IP" ]]; then

                echo "   🌐 $FQDN → $RESOLVED_IP" >&2

                if [[ "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then

                    echo "   ✅ Cached SSID confirmed by public IP" >&2
                    echo "$SSID"

                    return 0
                fi

                if [[ "$RESOLVED_IP" == "$LOCAL_CFG_IP" ]] &&
                   printf '%s\n' "$LOCAL_IPS" | grep -Fxq "$LOCAL_CFG_IP"; then

                    echo "   ✅ Cached SSID confirmed by local IP $LOCAL_CFG_IP" >&2
                    echo "$SSID"

                    return 0
                fi
            fi

            echo "   ⚠️ Cached SSID no longer matches" >&2

        done < "$ISP_CFG"
    fi

    # -----------------------------------------------------
    # Full detection
    # -----------------------------------------------------

    echo "🔍 Running full SSID detection..." >&2

    while IFS='=' read -r SSID FQDN LOCAL_CFG_IP; do

        [[ -z "$SSID" || "$SSID" =~ ^[[:space:]]*# ]] && continue
        [[ "$SSID" == "DETECTED_SSID" ]] && continue

        SSID="$(echo "$SSID" | xargs)"
        FQDN="$(echo "$FQDN" | xargs)"
        LOCAL_CFG_IP="$(echo "$LOCAL_CFG_IP" | xargs)"

        [[ -z "$SSID" || -z "$FQDN" || -z "$LOCAL_CFG_IP" ]] && continue

        echo "🔎 Testing $SSID → $FQDN=$LOCAL_CFG_IP" >&2

        RESOLVED_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null |
            awk 'NR==1 {print $1}')

        if [[ -z "$RESOLVED_IP" ]]; then
            echo "   ❌ Cannot resolve $FQDN" >&2
            continue
        fi

        echo "   🌐 $FQDN → $RESOLVED_IP" >&2

        if [[ "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then

            echo "   ✅ Public IP match: $PUBLIC_IP" >&2

            update_cached_ssid "$SSID"

            echo "📶 SSID found: $SSID" >&2
            echo "$SSID"

            return 0
        fi

        if [[ "$RESOLVED_IP" == "$LOCAL_CFG_IP" ]]; then

            if printf '%s\n' "$LOCAL_IPS" | grep -Fxq "$LOCAL_CFG_IP"; then

                echo "   ✅ Exact local IP match: $LOCAL_CFG_IP" >&2

                update_cached_ssid "$SSID"

                echo "📶 SSID found: $SSID" >&2
                echo "$SSID"

                return 0
            fi

            echo "   ⚠️ $LOCAL_CFG_IP is not assigned to this device" >&2
            continue
        fi

        echo "   ❌ No match for $SSID" >&2

    done < "$ISP_CFG"

    echo "❌ No SSID found for public IP: $PUBLIC_IP" >&2

    return 1
}

# =========================================================
# Send data to InfluxDB
# =========================================================

curl_influx() {

    local LINE="$1"
    local URL="http://${INFLUX_HOST}:8086/write?db=speedtest&u=monitor&p=${PASS}"

    echo "📡 Curl → influxdb:8086..."

    local ERR_FILE="/tmp/curl_err.$$"

    local HTTP_CODE

    HTTP_CODE=$(curl -s \
        -w "%{http_code}" \
        --connect-timeout 5 \
        --max-time 10 \
        --data-binary "${LINE}" \
        -o /dev/null \
        --stderr "$ERR_FILE" \
        "$URL")

    local CURL_EXIT=$?

    local CURL_ERR
    CURL_ERR=$(cat "$ERR_FILE" 2>/dev/null || echo "Unknown curl error")

    rm -f "$ERR_FILE"

    case $CURL_EXIT in

        0)
            if [[ "$HTTP_CODE" == "204" ]]; then
                echo "✅ SUCCESS HTTP: $HTTP_CODE"
                return 0
            fi

            echo "❌ HTTP ERROR: $HTTP_CODE"
            echo "   Line: ${LINE:0:100}..."

            [[ -n "$CURL_ERR" ]] && echo "   Curl: $CURL_ERR"

            return 1
            ;;

        6)
            echo "❌ DNS ERROR: Cannot resolve influxdb → Check Docker networking"
            return 1
            ;;

        7)
            echo "❌ CONNECT ERROR: Cannot reach influxdb:8086 → Check Docker container"
            return 1
            ;;

        28)
            echo "❌ TIMEOUT: influxdb:8086 → Network issue"
            return 1
            ;;

        *)
            echo "❌ CURL FAILED (exit $CURL_EXIT): $CURL_ERR"
            return 1
            ;;
    esac
}

# =========================================================
# Send JSON result to InfluxDB
# =========================================================

send() {

    local JSON="$1"

    [[ -z "$JSON" ]] && {
        echo "❌ No JSON output"
        return 1
    }

    local PUBLIC_IP

    PUBLIC_IP=$(detect_public_ip) || return 1

    local BOX

    BOX=$(detect_wifi_ssid)

    if [[ -n "$BOX" ]]; then

        echo "📶 Using Wi-Fi SSID: $BOX"

    else

        echo "ℹ️ Wi-Fi SSID not detected, using DNS/IP detection..." >&2

        BOX=$(detect_box "$PUBLIC_IP")

        if [[ $? -ne 0 || -z "$BOX" ]]; then
            echo "❌ No SSID found - speedtest result will NOT be sent"
            return 1
        fi
    fi

    echo "🌐 Public IP: $PUBLIC_IP"
    echo "📶 SSID: $BOX"

    # -----------------------------------------------------
    # Parse JSON
    # -----------------------------------------------------

    local PING
    local DL
    local UL

    if [[ "$SPEEDTEST_TYPE" == "ookla" ]]; then

        PING=$(echo "$JSON" | jq -r '.ping.latency // 0')
        DL=$(echo "$JSON" | jq -r '.download.bandwidth * 8 / 1000000 // 0')
        UL=$(echo "$JSON" | jq -r '.upload.bandwidth * 8 / 1000000 // 0')

    elif [[ "$SPEEDTEST_TYPE" == "speedtest-cli" ]]; then

        PING=$(echo "$JSON" | jq -r '.ping // 0')
        DL=$(echo "$JSON" | jq -r '.download / 1000000 // 0')
        UL=$(echo "$JSON" | jq -r '.upload / 1000000 // 0')

    else

        echo "❌ Unknown Speedtest type: $SPEEDTEST_TYPE"
        return 1
    fi

    if [[ "$PING" == "null" || "$DL" == "null" || "$UL" == "null" ]]; then

        echo "❌ Null values: ping=$PING dl=$DL ul=$UL"

        return 1
    fi

    # -----------------------------------------------------
    # InfluxDB line protocol
    # -----------------------------------------------------

    local LINE

    LINE="speedtest,host=${HOSTNAME},box=${BOX},interface=${BOX} ping=${PING},download=${DL},upload=${UL} ${TS}"

    echo "📤 Sending: $LINE"

    curl_influx "$LINE"
}

# =========================================================
# Main execution
# =========================================================

echo "🚀 Speedtest from $HOSTNAME → influxdb"
echo "🔧 Speedtest type: $SPEEDTEST_TYPE"

if [[ "$SPEEDTEST_TYPE" == "ookla" ]]; then

    LOCAL_JSON=$(speedtest \
        --accept-license \
        --accept-gdpr \
        -f json 2>/dev/null)

elif [[ "$SPEEDTEST_TYPE" == "speedtest-cli" ]]; then

    LOCAL_JSON=$(speedtest-cli --json 2>/dev/null)

else

    echo "❌ FATAL: Unsupported Speedtest type"
    exit 1
fi

if [[ -z "$LOCAL_JSON" ]]; then
    echo "❌ Speedtest returned no JSON output"
    exit 1
fi

send "$LOCAL_JSON"

RESULT=$?

if [[ $RESULT -eq 0 ]]; then
    echo "✅ Complete: $(date)"
else
    echo "❌ Failed: $(date)"
fi

exit $RESULT
