#!/bin/bash

# --- Script directory / ISP configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISP_CFG="${SCRIPT_DIR}/isp.cfg"

if [[ ! -f "$ISP_CFG" ]]; then
    echo "❌ FATAL: ISP configuration file not found: $ISP_CFG"
    exit 1
fi

# --- Check/Install speedtest (Debian Trixie ARM64) ---
if ! command -v speedtest >/dev/null 2>&1; then
    echo "📦 Installing Ookla speedtest CLI..."
    sudo apt update
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
    sudo apt install speedtest -y
    echo "✅ Speedtest installed"
else
    echo "✅ Speedtest already installed"
fi

# --- Configuration (uses Docker hostname 'influxdb') ---
INFLUX_HOST="influxdb"
PASS=$(sudo cat /etc/speedtest/influxdb_pass) || { echo "❌ FATAL: Cannot read InfluxDB password"; exit 1; }
TS=$(date +%s%N)
CMD="speedtest --accept-license --accept-gdpr -f json"
HOSTNAME=$(hostname)

# Si connecté en wifi, alors récupérer le SSID via iw)
detect_wifi_ssid() {
    local SSID

    # Try wlan0 first
    if command -v iw >/dev/null 2>&1; then
        SSID=$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')

        if [[ -n "$SSID" ]]; then
            echo "📶 Wi-Fi SSID detected: $SSID" >&2
            echo "$SSID"
            return 0
        fi
    fi

    return 1
}
# --- Detect public IP ---
detect_public_ip() {
    local PUBLIC_IP

    PUBLIC_IP=$(curl -4 -s --connect-timeout 5 --max-time 10 https://api.ipify.org)

    if [[ -z "$PUBLIC_IP" ]]; then
        echo "❌ Unable to detect public IPv4 address" >&2
        return 1
    fi

    echo "$PUBLIC_IP"
}
#
update_cached_ssid() {
    local SSID="$1"
    local TMP_CFG="${ISP_CFG}.tmp"

    # Remove previous cached SSID line
    grep -vE '^[[:space:]]*#?[[:space:]]*DETECTED_SSID=' "$ISP_CFG" > "$TMP_CFG"

    # Add new cached SSID at the top
    {
        echo "# DETECTED_SSID=$SSID"
        cat "$TMP_CFG"
    } > "${TMP_CFG}.new"

    mv "${TMP_CFG}.new" "$ISP_CFG"
    rm -f "$TMP_CFG"

    echo "💾 Cached SSID updated: $SSID" >&2
}

# --- Detect ISP/SSID from public IP using isp.cfg ---
detect_box() {
    local PUBLIC_IP="$1"
    local SSID FQDN LOCAL_CFG_IP RESOLVED_IP
    local CACHED_SSID=""
    local LOCAL_IPS

    # Get all IPv4 addresses assigned to this device
    LOCAL_IPS=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1)

    echo "🖧 Local device IPs: $(echo "$LOCAL_IPS" | tr '\n' ' ')" >&2

    # ---------------------------------------------------------
    # Read cached SSID
    # ---------------------------------------------------------
    CACHED_SSID=$(awk -F= '/^[[:space:]]*#?[[:space:]]*DETECTED_SSID=/ {
        sub(/^[[:space:]]*#?[[:space:]]*DETECTED_SSID=/, "", $0)
        gsub(/[[:space:]]/, "", $0)
        print $0
        exit
    }' "$ISP_CFG")

    if [[ -n "$CACHED_SSID" ]]; then
        echo "⚡ Cached SSID: $CACHED_SSID" >&2

        while IFS='=' read -r SSID FQDN LOCAL_CFG_IP; do
            [[ "$SSID" != "$CACHED_SSID" ]] && continue

            SSID="$(echo "$SSID" | xargs)"
            FQDN="$(echo "$FQDN" | xargs)"
            LOCAL_CFG_IP="$(echo "$LOCAL_CFG_IP" | xargs)"

            [[ -z "$FQDN" || -z "$LOCAL_CFG_IP" ]] && continue

            echo "🔎 Fast check: $SSID → $FQDN=$LOCAL_CFG_IP" >&2

            RESOLVED_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null | awk 'NR==1 {print $1}')

            if [[ -n "$RESOLVED_IP" ]]; then
                echo "   🌐 $FQDN → $RESOLVED_IP" >&2

                # Public IP match
                if [[ "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then
                    echo "   ✅ Cached SSID confirmed by public IP" >&2
                    echo "$SSID"
                    return 0
                fi

                # Exact local IP match
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

    # ---------------------------------------------------------
    # Full detection
    # ---------------------------------------------------------
    echo "🔍 Running full SSID detection..." >&2

    while IFS='=' read -r SSID FQDN LOCAL_CFG_IP; do
        [[ -z "$SSID" || "$SSID" =~ ^[[:space:]]*# ]] && continue
        [[ "$SSID" == "DETECTED_SSID" ]] && continue

        SSID="$(echo "$SSID" | xargs)"
        FQDN="$(echo "$FQDN" | xargs)"
        LOCAL_CFG_IP="$(echo "$LOCAL_CFG_IP" | xargs)"

        [[ -z "$SSID" || -z "$FQDN" || -z "$LOCAL_CFG_IP" ]] && continue

        echo "🔎 Testing $SSID → $FQDN=$LOCAL_CFG_IP" >&2

        RESOLVED_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null | awk 'NR==1 {print $1}')

        if [[ -z "$RESOLVED_IP" ]]; then
            echo "   ❌ Cannot resolve $FQDN" >&2
            continue
        fi

        echo "   🌐 $FQDN → $RESOLVED_IP" >&2

        # Public IP match
        if [[ "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then
            echo "   ✅ Public IP match: $PUBLIC_IP" >&2

            update_cached_ssid "$SSID"

            echo "📶 SSID found: $SSID" >&2
            echo "$SSID"
            return 0
        fi

        # Exact local IP match
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
# --- Enhanced curl with full error reporting ---
curl_influx() {
    local LINE="$1"
    local URL="http://${INFLUX_HOST}:8086/write?db=speedtest&u=monitor&p=${PASS}"
    
    echo "📡 Curl → influxdb:8086..."
    
    local HTTP_CODE=$(curl -s -w "%{http_code}" \
      --connect-timeout 5 \
      --max-time 10 \
      --data-binary "${LINE}" \
      -o /dev/null \
      --stderr /tmp/curl_err.$$ \
      "$URL")
    
    local CURL_EXIT=$?
    local CURL_ERR=$(cat /tmp/curl_err.$$ 2>/dev/null || echo "Unknown curl error")
    rm -f /tmp/curl_err.$$
    
    case $CURL_EXIT in
      0)
        if [[ "$HTTP_CODE" == "204" ]]; then
          echo "✅ SUCCESS HTTP: $HTTP_CODE"
          return 0
        else
          echo "❌ HTTP ERROR: $HTTP_CODE"
          echo "   Line: ${LINE:0:100}..."
          [[ -n "$CURL_ERR" ]] && echo "   Curl: $CURL_ERR"
          return 1
        fi
        ;;
      6) echo "❌ DNS ERROR: Cannot resolve influxdb → Check Docker networking"; return 1 ;;
      7) echo "❌ CONNECT ERROR: Cannot reach influxdb:8086 → Check Docker container"; return 1 ;;
      28) echo "❌ TIMEOUT: influxdb:8086 → Network issue"; return 1 ;;
      *) echo "❌ CURL FAILED (exit $CURL_EXIT): $CURL_ERR"; return 1 ;;
    esac
}

# --- Send JSON result to InfluxDB ---
send() {
    local JSON="$1"
    [[ -z "$JSON" ]] && { echo "❌ No JSON output"; return 1; }

    local PUBLIC_IP
    PUBLIC_IP=$(detect_public_ip) || return 1

    local BOX

    BOX=$(detect_wifi_ssid)

    if [[ -n "$BOX" ]]; then
        echo "📶 Using Wi-Fi SSID: $BOX"
    else
        echo "ℹ️ Wi-Fi SSID not detected, using DNS/IP detection..." >&2

        local PUBLIC_IP
        PUBLIC_IP=$(detect_public_ip) || return 1

        BOX=$(detect_box "$PUBLIC_IP")

        if [[ $? -ne 0 || -z "$BOX" ]]; then
            echo "❌ No SSID found - speedtest result will NOT be sent"
            return 1
       fi
    fi

    echo "🌐 Public IP: $PUBLIC_IP"
    echo "📶 SSID: $BOX"

    local PING=$(echo "$JSON" | jq -r '.ping.latency // 0')
    local DL=$(echo "$JSON" | jq -r '.download.bandwidth * 8 / 1000000 // 0')
    local UL=$(echo "$JSON" | jq -r '.upload.bandwidth * 8 / 1000000 // 0')

    [[ "$PING" == "null" || "$DL" == "null" || "$UL" == "null" ]] && { 
        echo "❌ Null values: ping=$PING dl=$DL ul=$UL"; 
        return 1; 
    }

    local LINE="speedtest,host=${HOSTNAME},box=${BOX},interface=${BOX} ping=${PING},download=${DL},upload=${UL} ${TS}"
    echo "📤 Sending: $LINE"
    
    curl_influx "$LINE"
}

# --- Main execution ---
echo "🚀 Speedtest from $HOSTNAME → influxdb"
LOCAL_JSON=$($CMD 2>/dev/null)
send "$LOCAL_JSON"
echo "✅ Complete: $(date)"
