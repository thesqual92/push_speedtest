#!/bin/bash

# =========================================================
# push_speedtest.sh
# Raspberry Pi OS / Debian Trixie
#
# ARM64 -> Ookla speedtest
# ARMHF -> Debian speedtest-cli
#
# Interface selection:
#
# 1. wlan0 has no gateway
#       -> NO SPEEDTEST
#
# 2. eth0 and wlan0 have the SAME gateway
#       -> SPEEDTEST ON eth0
#
# 3. eth0 and wlan0 have DIFFERENT gateways
#       -> SPEEDTEST ON wlan0
#
# 4. eth0 has no gateway, wlan0 has a gateway
#       -> SPEEDTEST ON wlan0
#
# 5. eth0 has a gateway, wlan0 has no gateway
#       -> NO SPEEDTEST
#
# The selected interface is explicitly forced:
#
# Ookla:
#       --interface eth0
#       --interface wlan0
#
# speedtest-cli:
#       --source <interface IPv4>
# =========================================================

set -o pipefail

# =========================================================
# Command-line options
# =========================================================

NO_DATABASE_UPLOAD=false

for ARG in "$@"; do
    case "$ARG" in
        --no-database-upload)
            NO_DATABASE_UPLOAD=true
            ;;
        -h|--help)
            echo "Usage: $0 [--no-database-upload]"
            echo
            echo "Options:"
            echo "  --no-database-upload   Run Speedtest without writing to InfluxDB"
            echo "  -h, --help             Show this help"
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $ARG"
            echo "Usage: $0 [--no-database-upload]"
            exit 1
            ;;
    esac
done

# =========================================================
# Start datetime / execution timer
# =========================================================

START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
START_TS=$(date +%s)

echo "🕐 Start: $START_DATETIME"

# =========================================================
# Script directory / ISP configuration
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISP_CFG="${SCRIPT_DIR}/isp.cfg"

if [[ ! -f "$ISP_CFG" ]]; then
    echo "❌ FATAL: ISP configuration file not found: $ISP_CFG"
    exit 1
fi

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

SPEEDTEST_TYPE=""

SELECTED_INTERFACE=""
SELECTED_IP=""
SELECTED_GATEWAY=""
SELECTED_SSID=""

ETH0_IP=""
ETH0_GATEWAY=""

WLAN0_IP=""
WLAN0_GATEWAY=""

# =========================================================
# Detect architecture / Speedtest implementation
# =========================================================

detect_speedtest() {

    local ARCH

    ARCH=$(dpkg --print-architecture 2>/dev/null)

    echo "🖥️ Architecture: ${ARCH:-unknown}"

    # -----------------------------------------------------
    # ARMHF / 32-bit
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

        echo "✅ Using Debian speedtest-cli: $(command -v speedtest-cli)"

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

        echo "📦 Installing Ookla speedtest CLI..."

        sudo apt update || {
            echo "❌ FATAL: apt update failed"
            return 1
        }

        curl -s \
            https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh |
            sudo bash || {
                echo "❌ FATAL: Failed to configure Ookla speedtest repository"
                return 1
            }

        sudo apt install -y speedtest || {
            echo "❌ FATAL: Unable to install speedtest"
            return 1
        }

        if ! command -v speedtest >/dev/null 2>&1; then
            echo "❌ FATAL: Ookla speedtest installation failed"
            return 1
        fi

        SPEEDTEST_TYPE="ookla"

        echo "✅ Using Ookla speedtest: $(command -v speedtest)"

        return 0
    fi

    echo "❌ FATAL: Unsupported architecture: ${ARCH:-unknown}"

    return 1
}

detect_speedtest || exit 1

# =========================================================
# Get IPv4 address of interface
# =========================================================

get_interface_ip() {

    local INTERFACE="$1"

    ip -4 addr show "$INTERFACE" 2>/dev/null |
        awk '/inet / {print $2}' |
        cut -d/ -f1 |
        head -n1
}

# =========================================================
# Get IPv4 gateway of interface
# =========================================================

get_interface_gateway() {

    local INTERFACE="$1"
    local GATEWAY=""

    # First try routing table
    GATEWAY=$(ip -4 route show dev "$INTERFACE" 2>/dev/null |
        awk '$1 == "default" && $2 == "via" {print $3; exit}')

    # Fallback to NetworkManager
    if [[ -z "$GATEWAY" ]] &&
       command -v nmcli >/dev/null 2>&1; then

        GATEWAY=$(nmcli -g IP4.GATEWAY device show "$INTERFACE" 2>/dev/null |
            head -n1 |
            tr -d '[:space:]')
    fi

    echo "$GATEWAY"
}

# =========================================================
# Get Wi-Fi SSID
# =========================================================

get_wifi_ssid() {

    local INTERFACE="$1"

    if ! command -v iw >/dev/null 2>&1; then
        return 1
    fi

    iw dev "$INTERFACE" link 2>/dev/null |
        awk -F': ' '/SSID:/ {print $2; exit}'
}

# =========================================================
# Select Speedtest interface
# =========================================================

select_interface() {

    ETH0_IP=$(get_interface_ip "eth0")
    ETH0_GATEWAY=$(get_interface_gateway "eth0")

    WLAN0_IP=$(get_interface_ip "wlan0")
    WLAN0_GATEWAY=$(get_interface_gateway "wlan0")

    echo "🌐 eth0  IPv4: ${ETH0_IP:-none}"
    echo "🚪 eth0  gateway: ${ETH0_GATEWAY:-none}"

    echo "📶 wlan0 IPv4: ${WLAN0_IP:-none}"
    echo "🚪 wlan0 gateway: ${WLAN0_GATEWAY:-none}"

    # -----------------------------------------------------
    # wlan0 MUST have a gateway
    # -----------------------------------------------------

    if [[ -z "$WLAN0_GATEWAY" ]]; then

        echo "🛑 wlan0 has no IPv4 gateway"
        echo "🛑 Wi-Fi cannot be used for the requested Speedtest"
        echo "🛑 Speedtest will NOT be executed"

        return 1
    fi

    # -----------------------------------------------------
    # eth0 and wlan0 have the same gateway
    #
    # Ethernet is preferred because it is faster.
    # -----------------------------------------------------

    if [[ -n "$ETH0_GATEWAY" &&
          "$ETH0_GATEWAY" == "$WLAN0_GATEWAY" ]]; then

        if [[ -z "$ETH0_IP" ]]; then

            echo "⚠️ eth0 has gateway but no IPv4 address"
            echo "➡️ Falling back to wlan0"

        else

            SELECTED_INTERFACE="eth0"
            SELECTED_IP="$ETH0_IP"
            SELECTED_GATEWAY="$ETH0_GATEWAY"
            SELECTED_SSID=""

            echo "🔀 eth0 and wlan0 use the SAME gateway"
            echo "⚡ Ethernet is preferred"
            echo "✅ Speedtest interface: eth0"
            echo "🌐 Source IP: $SELECTED_IP"
            echo "🚪 Gateway: $SELECTED_GATEWAY"

            return 0
        fi
    fi

    # -----------------------------------------------------
    # Different gateways
    #
    # This means the Wi-Fi is potentially another Internet
    # connection, for example an iPhone hotspot.
    # -----------------------------------------------------

    if [[ -n "$ETH0_GATEWAY" &&
          "$ETH0_GATEWAY" != "$WLAN0_GATEWAY" ]]; then

        SELECTED_INTERFACE="wlan0"
        SELECTED_IP="$WLAN0_IP"
        SELECTED_GATEWAY="$WLAN0_GATEWAY"

        SELECTED_SSID=$(get_wifi_ssid "wlan0")

        if [[ -z "$SELECTED_SSID" ]]; then

            echo "🛑 Unable to determine Wi-Fi SSID"
            echo "🛑 Speedtest will NOT be executed"

            return 1
        fi

        echo "🔀 eth0 and wlan0 use DIFFERENT gateways"
        echo "📶 Wi-Fi is considered a separate Internet connection"
        echo "✅ Speedtest interface: wlan0"
        echo "🌐 Source IP: $SELECTED_IP"
        echo "🚪 Gateway: $SELECTED_GATEWAY"
        echo "📶 SSID: $SELECTED_SSID"

        return 0
    fi

    # -----------------------------------------------------
    # eth0 has no gateway
    # wlan0 has gateway
    # -----------------------------------------------------

    if [[ -z "$ETH0_GATEWAY" ]]; then

        SELECTED_INTERFACE="wlan0"
        SELECTED_IP="$WLAN0_IP"
        SELECTED_GATEWAY="$WLAN0_GATEWAY"

        SELECTED_SSID=$(get_wifi_ssid "wlan0")

        if [[ -z "$SELECTED_SSID" ]]; then

            echo "🛑 Unable to determine Wi-Fi SSID"
            echo "🛑 Speedtest will NOT be executed"

            return 1
        fi

        echo "ℹ️ eth0 has no gateway"
        echo "📶 wlan0 has gateway"
        echo "✅ Speedtest interface: wlan0"
        echo "🌐 Source IP: $SELECTED_IP"
        echo "🚪 Gateway: $SELECTED_GATEWAY"
        echo "📶 SSID: $SELECTED_SSID"

        return 0
    fi

    # -----------------------------------------------------
    # Fallback
    # -----------------------------------------------------

    echo "🛑 No valid Internet interface combination found"

    return 1
}

# =========================================================
# Escape InfluxDB tag
#
# Required for:
#
#   iPhone P
#   My,SSID
#   SSID=xxx
#   SSID\xxx
# =========================================================

escape_influx_tag() {

    local VALUE="$1"

    VALUE="${VALUE//\\/\\\\}"
    VALUE="${VALUE// /\\ }"
    VALUE="${VALUE//,/\\,}"
    VALUE="${VALUE//=/\\=}"

    echo "$VALUE"
}

# =========================================================
# Detect box from public IP using isp.cfg
#
# Used when Speedtest is executed through Ethernet.
# =========================================================

detect_box() {

    local PUBLIC_IP="$1"

    local SSID
    local FQDN
    local LOCAL_CFG_IP
    local RESOLVED_IP
    local CACHED_SSID=""
    local LOCAL_IPS

    LOCAL_IPS=$(ip -4 addr show scope global 2>/dev/null |
        awk '/inet / {print $2}' |
        cut -d/ -f1)

    echo "🖧 Local device IPs: $(echo "$LOCAL_IPS" | tr '\n' ' ')" >&2

    # -----------------------------------------------------
    # Read cached SSID
    # -----------------------------------------------------

    CACHED_SSID=$(awk -F= '
        /^[[:space:]]*#?[[:space:]]*DETECTED_SSID=/ {
            sub(/^[[:space:]]*#?[[:space:]]*DETECTED_SSID=/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
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

            RESOLVED_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null |
                awk 'NR==1 {print $1}')

            if [[ -n "$RESOLVED_IP" ]]; then

                if [[ "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then

                    echo "   ✅ Cached box confirmed by public IP" >&2
                    echo "$SSID"

                    return 0
                fi

                if [[ "$RESOLVED_IP" == "$LOCAL_CFG_IP" ]] &&
                   printf '%s\n' "$LOCAL_IPS" |
                   grep -Fxq "$LOCAL_CFG_IP"; then

                    echo "   ✅ Cached box confirmed by local IP" >&2
                    echo "$SSID"

                    return 0
                fi
            fi

        done < "$ISP_CFG"
    fi

    # -----------------------------------------------------
    # Full detection
    # -----------------------------------------------------

    echo "🔍 Running full ISP detection..." >&2

    while IFS='=' read -r SSID FQDN LOCAL_CFG_IP; do

        [[ -z "$SSID" ]] && continue
        [[ "$SSID" =~ ^[[:space:]]*# ]] && continue
        [[ "$SSID" == "DETECTED_SSID" ]] && continue

        SSID="$(echo "$SSID" | xargs)"
        FQDN="$(echo "$FQDN" | xargs)"
        LOCAL_CFG_IP="$(echo "$LOCAL_CFG_IP" | xargs)"

        [[ -z "$SSID" ||
           -z "$FQDN" ||
           -z "$LOCAL_CFG_IP" ]] && continue

        echo "🔎 Testing $SSID → $FQDN=$LOCAL_CFG_IP" >&2

        RESOLVED_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null |
            awk 'NR==1 {print $1}')

        if [[ -z "$RESOLVED_IP" ]]; then
            continue
        fi

        # -------------------------------------------------
        # Public IP match
        # -------------------------------------------------

        if [[ "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then

            echo "   ✅ Public IP match: $PUBLIC_IP" >&2

            echo "$SSID"

            return 0
        fi

        # -------------------------------------------------
        # Local IP match
        # -------------------------------------------------

        if [[ "$RESOLVED_IP" == "$LOCAL_CFG_IP" ]] &&
           printf '%s\n' "$LOCAL_IPS" |
           grep -Fxq "$LOCAL_CFG_IP"; then

            echo "   ✅ Local IP match: $LOCAL_CFG_IP" >&2

            echo "$SSID"

            return 0
        fi

    done < "$ISP_CFG"

    echo "❌ No ISP/box found for public IP: $PUBLIC_IP" >&2

    return 1
}

# =========================================================
# Send data to InfluxDB
# =========================================================

curl_influx() {

    local LINE="$1"

    if [[ "$NO_DATABASE_UPLOAD" == true ]]; then
        echo "⏭️ Database upload disabled (--no-database-upload)"
        echo "📤 Would send: $LINE"
        return 0
    fi

    local URL="http://${INFLUX_HOST}:8086/write?db=speedtest&u=monitor&p=${PASS}"

    echo "📡 Curl → influxdb:8086..."
    local ERR_FILE="/tmp/curl_err.$$"
    local HTTP_CODE

    HTTP_CODE=$(curl -s \
        -w "%{http_code}" \
        --connect-timeout 5 \
        --max-time 10 \
        --data-binary "$LINE" \
        -o /dev/null \
        --stderr "$ERR_FILE" \
        "$URL")

    local CURL_EXIT=$?

    local CURL_ERR
    CURL_ERR=$(cat "$ERR_FILE" 2>/dev/null || echo "Unknown curl error")

    rm -f "$ERR_FILE"

    case "$CURL_EXIT" in

        0)

            if [[ "$HTTP_CODE" == "204" ]]; then

                echo "✅ SUCCESS HTTP: $HTTP_CODE"

                return 0
            fi

            echo "❌ HTTP ERROR: $HTTP_CODE"
            echo "   Line: ${LINE:0:200}..."

            [[ -n "$CURL_ERR" ]] &&
                echo "   Curl: $CURL_ERR"

            return 1
            ;;

        6)

            echo "❌ DNS ERROR: Cannot resolve influxdb"

            return 1
            ;;

        7)

            echo "❌ CONNECT ERROR: Cannot reach influxdb:8086"

            return 1
            ;;

        28)

            echo "❌ TIMEOUT: influxdb:8086"

            return 1
            ;;

        *)

            echo "❌ CURL FAILED (exit $CURL_EXIT): $CURL_ERR"

            return 1
            ;;
    esac
}

# =========================================================
# Send Speedtest JSON
# =========================================================

send() {

    local JSON="$1"

    if [[ -z "$JSON" ]]; then

        echo "❌ No JSON output"

        return 1
    fi

    # -----------------------------------------------------
    # Public IP
    # -----------------------------------------------------

    local PUBLIC_IP

    if [[ "$SPEEDTEST_TYPE" == "speedtest-cli" ]]; then

        PUBLIC_IP=$(echo "$JSON" |
            jq -r '.client.ip // empty')

    elif [[ "$SPEEDTEST_TYPE" == "ookla" ]]; then

        PUBLIC_IP=$(echo "$JSON" |
            jq -r '.interface.externalIp // empty')

    else

        echo "❌ Unknown Speedtest type"

        return 1
    fi

    if [[ -z "$PUBLIC_IP" ]]; then

        echo "❌ Unable to detect public IPv4 address from Speedtest JSON"

        return 1
    fi

    # -----------------------------------------------------
    # Determine box / SSID
    # -----------------------------------------------------

    local BOX

    if [[ "$SELECTED_INTERFACE" == "wlan0" ]]; then

        BOX="$SELECTED_SSID"

    else

        BOX=$(detect_box "$PUBLIC_IP")

        if [[ $? -ne 0 || -z "$BOX" ]]; then

            echo "❌ Unable to identify ISP/box for Ethernet"

            return 1
        fi
    fi

    # -----------------------------------------------------
    # Parse Speedtest values
    # -----------------------------------------------------

    local PING
    local DL
    local UL

    if [[ "$SPEEDTEST_TYPE" == "ookla" ]]; then

        PING=$(echo "$JSON" |
            jq -r '.ping.latency // 0')

        DL=$(echo "$JSON" |
            jq -r '(.download.bandwidth * 8 / 1000000) // 0')

        UL=$(echo "$JSON" |
            jq -r '(.upload.bandwidth * 8 / 1000000) // 0')

    else

        PING=$(echo "$JSON" |
            jq -r '.ping // 0')

        DL=$(echo "$JSON" |
            jq -r '(.download / 1000000) // 0')

        UL=$(echo "$JSON" |
            jq -r '(.upload / 1000000) // 0')

    fi

    if [[ "$PING" == "null" ||
          "$DL" == "null" ||
          "$UL" == "null" ]]; then

        echo "❌ Null values: ping=$PING dl=$DL ul=$UL"

        return 1
    fi

    # -----------------------------------------------------
    # Escape InfluxDB tags
    # -----------------------------------------------------

    local HOSTNAME_ESCAPED
    local BOX_ESCAPED
    local INTERFACE_ESCAPED

    HOSTNAME_ESCAPED=$(escape_influx_tag "$HOSTNAME")
    BOX_ESCAPED=$(escape_influx_tag "$BOX")
    INTERFACE_ESCAPED=$(escape_influx_tag "$BOX")

    # -----------------------------------------------------
    # InfluxDB line protocol
    #
    # Tags:
    #   host
    #   box
    #   interface
    #
    # Fields:
    #   ping
    #   download
    #   upload
    #
    # The SPACE before ping is intentional.
    # There is NO comma before ping.
    # -----------------------------------------------------

    local LINE

    LINE="speedtest,host=${HOSTNAME_ESCAPED},box=${BOX_ESCAPED},interface=${INTERFACE_ESCAPED} ping=${PING},download=${DL},upload=${UL} ${TS}"

    echo "🌐 Public IP: $PUBLIC_IP"
    echo "📡 Speedtest interface: $SELECTED_INTERFACE"
    echo "📦 Box/SSID: $BOX"
    echo "📤 Sending: $LINE"

    curl_influx "$LINE"
}

# =========================================================
# Main execution
# =========================================================

echo "🚀 Speedtest from $HOSTNAME → influxdb"

if [[ "$NO_DATABASE_UPLOAD" == true ]]; then
    echo "🧪 Database upload: DISABLED"
else
    echo "💾 Database upload: ENABLED"
fi
echo "🔧 Speedtest type: $SPEEDTEST_TYPE"

# =========================================================
# Select interface
# =========================================================

if ! select_interface; then

    RESULT=0

else

    echo
    echo "========================================================="
    echo "🏃 SPEEDTEST"
    echo "========================================================="

    # -----------------------------------------------------
    # Ookla
    # -----------------------------------------------------

    if [[ "$SPEEDTEST_TYPE" == "ookla" ]]; then

        echo "🏃 Running Ookla on $SELECTED_INTERFACE..."

        LOCAL_JSON=$(speedtest \
            --accept-license \
            --accept-gdpr \
            --interface "$SELECTED_INTERFACE" \
            -f json 2>/dev/null)

    # -----------------------------------------------------
    # speedtest-cli
    # -----------------------------------------------------

    elif [[ "$SPEEDTEST_TYPE" == "speedtest-cli" ]]; then

        echo "🏃 Running speedtest-cli from $SELECTED_IP..."

        LOCAL_JSON=$(speedtest-cli \
            --source "$SELECTED_IP" \
            --json 2>/dev/null)

    else

        echo "❌ FATAL: Unsupported Speedtest type"

        RESULT=1
        LOCAL_JSON=""
    fi

    # -----------------------------------------------------
    # Validate JSON
    # -----------------------------------------------------

    if [[ -z "$LOCAL_JSON" ]]; then

        echo "❌ Speedtest returned no JSON output"

        RESULT=1

    elif ! echo "$LOCAL_JSON" | jq empty >/dev/null 2>&1; then

        echo "❌ Speedtest returned invalid JSON"

        RESULT=1

    else

        echo "✅ Valid Speedtest JSON received"

        send "$LOCAL_JSON"
        RESULT=$?

    fi
fi

# =========================================================
# End datetime / execution duration
# =========================================================

END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
END_TS=$(date +%s)

DURATION=$((END_TS - START_TS))

echo "🕐 End:   $END_DATETIME"
echo "⏱️ Duration: ${DURATION}s"

if [[ $RESULT -eq 0 ]]; then

    echo "✅ Complete: $END_DATETIME"

else

    echo "❌ Failed: $END_DATETIME"

fi

exit "$RESULT"
