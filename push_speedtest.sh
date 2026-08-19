#!/bin/bash

# =========================================================
# push_speedtest.sh
# Raspberry Pi OS / Debian Trixie
#
# ARM64 -> Ookla speedtest
# ARMHF -> Debian speedtest-cli
#
# Internet must use wlan0 unless ISP.cfg explicitly
# allows an Ethernet interface.
# =========================================================

set -o pipefail

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
HOSTNAME=$(hostname)

PASS=$(sudo cat /etc/speedtest/influxdb_pass 2>/dev/null) || {
    echo "❌ FATAL: Cannot read InfluxDB password"
    exit 1
}

if [[ -z "$PASS" ]]; then
    echo "❌ FATAL: InfluxDB password is empty"
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

        echo "📦 Installing Ookla speedtest CLI..."

        sudo apt update || {
            echo "❌ FATAL: apt update failed"
            return 1
        }

        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh |
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

        echo "✅ Ookla speedtest installed: $(command -v speedtest)"

        return 0
    fi

    echo "❌ FATAL: Unsupported architecture: ${ARCH:-unknown}"

    return 1
}

detect_speedtest || exit 1

# =========================================================
# Get Internet route
# =========================================================

get_internet_route() {

    local ROUTE

    ROUTE=$(ip route get 1.1.1.1 2>/dev/null | head -n1)

    if [[ -z "$ROUTE" ]]; then
        echo "❌ Unable to determine Internet route" >&2
        return 1
    fi

    echo "$ROUTE"

    return 0
}

# =========================================================
# Get interface used for Internet
# =========================================================

get_internet_interface() {

    local ROUTE
    local INTERFACE

    ROUTE=$(get_internet_route) || return 1

    INTERFACE=$(echo "$ROUTE" |
        sed -nE 's/.* dev ([^ ]+).*/\1/p')

    if [[ -z "$INTERFACE" ]]; then
        echo "❌ Unable to determine Internet interface" >&2
        return 1
    fi

    echo "$INTERFACE"

    return 0
}

# =========================================================
# Get Internet gateway
# =========================================================

get_internet_gateway() {

    local ROUTE
    local GATEWAY

    ROUTE=$(get_internet_route) || return 1

    GATEWAY=$(echo "$ROUTE" |
        sed -nE 's/.* via ([^ ]+).*/\1/p')

    echo "$GATEWAY"

    return 0
}

# =========================================================
# Detect Wi-Fi SSID
# =========================================================

detect_wifi_ssid() {

    local INTERFACE="${1:-wlan0}"
    local SSID

    if ! command -v iw >/dev/null 2>&1; then
        return 1
    fi

    SSID=$(iw dev "$INTERFACE" link 2>/dev/null |
        awk -F': ' '/SSID:/ {print $2; exit}')

    if [[ -n "$SSID" ]]; then
        echo "📶 Wi-Fi SSID detected on $INTERFACE: $SSID" >&2
        echo "$SSID"
        return 0
    fi

    return 1
}

# =========================================================
# Read configured SSIDs
#
# Normal format:
#
# SSID=FQDN=LOCAL_IP
#
# Example:
#
# Livebox-D8B0=livebox.example.net=192.168.1.1
# iPhone P=iphone.example.net=172.20.10.1
#
# Optional explicit Ethernet test:
#
# TEST_INTERFACE=eth0
#
# If TEST_INTERFACE exists, an Ethernet Internet route
# is allowed.
# =========================================================

get_configured_test_interface() {

    local VALUE

    VALUE=$(awk -F= '
        /^[[:space:]]*TEST_INTERFACE[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print $0
            exit
        }
    ' "$ISP_CFG")

    echo "$VALUE"
}

# =========================================================
# Determine whether current Internet route is allowed
# =========================================================

check_internet_interface() {

    local INTERFACE
    local GATEWAY
    local ALLOWED_ETHERNET

    INTERFACE=$(get_internet_interface) || return 1
    GATEWAY=$(get_internet_gateway)

    echo "🌐 Internet interface: $INTERFACE"
    [[ -n "$GATEWAY" ]] && echo "🚪 Internet gateway: $GATEWAY"

    # -----------------------------------------------------
    # Wi-Fi is the normal/expected case
    # -----------------------------------------------------

    if [[ "$INTERFACE" == "wlan0" ]]; then

        echo "✅ Internet uses wlan0"

        return 0
    fi

    # -----------------------------------------------------
    # Ethernet
    # -----------------------------------------------------

    ALLOWED_ETHERNET=$(get_configured_test_interface)

    if [[ -n "$ALLOWED_ETHERNET" &&
          "$INTERFACE" == "$ALLOWED_ETHERNET" ]]; then

        echo "⚠️ Internet uses $INTERFACE"
        echo "✅ Ethernet test explicitly allowed by isp.cfg"

        return 0
    fi

    echo "🛑 Internet uses $INTERFACE"
    echo "🛑 Wi-Fi is not being used for Internet"
    echo "🛑 Speedtest will NOT be executed"

    return 2
}

# =========================================================
# Escape InfluxDB tag value
#
# Escape:
#   \  -> \\
#   space -> \ 
#   , -> \,
#   = -> \=
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
# Send data to InfluxDB
# =========================================================

curl_influx() {

    local LINE="$1"

    local URL
    URL="http://${INFLUX_HOST}:8086/write?db=speedtest&u=monitor&p=${PASS}"

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

    case "$CURL_EXIT" in

        0)

            if [[ "$HTTP_CODE" == "204" ]]; then

                echo "✅ SUCCESS HTTP: $HTTP_CODE"

                return 0
            fi

            echo "❌ HTTP ERROR: $HTTP_CODE"
            echo "   Line: ${LINE:0:200}"

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
# Send Speedtest result
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
    # Determine SSID
    # -----------------------------------------------------

    local INTERFACE
    local BOX

    INTERFACE=$(get_internet_interface) || {

        echo "❌ Unable to determine Internet interface"

        return 1
    }

    if [[ "$INTERFACE" == "wlan0" ]]; then

        BOX=$(detect_wifi_ssid "$INTERFACE") || {

            echo "❌ Internet uses wlan0 but SSID could not be detected"

            return 1
        }

    else

        # Ethernet is only possible if explicitly allowed
        BOX=$(get_configured_test_interface)

        if [[ "$INTERFACE" != "$BOX" ]]; then

            echo "❌ Internet uses $INTERFACE but this interface is not allowed"

            return 1
        fi

        # For Ethernet, use interface name as box unless an
        # explicit mapping is added later.
        BOX="$INTERFACE"

        echo "⚠️ Ethernet speedtest: using interface name as box: $BOX"
    fi

    echo "🌐 Public IP: $PUBLIC_IP"
    echo "🔌 Internet interface: $INTERFACE"
    echo "📶 Box/SSID: $BOX"

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
            jq -r '(.download.bandwidth // 0) * 8 / 1000000')

        UL=$(echo "$JSON" |
            jq -r '(.upload.bandwidth // 0) * 8 / 1000000')

    elif [[ "$SPEEDTEST_TYPE" == "speedtest-cli" ]]; then

        PING=$(echo "$JSON" |
            jq -r '.ping // 0')

        DL=$(echo "$JSON" |
            jq -r '(.download // 0) / 1000000')

        UL=$(echo "$JSON" |
            jq -r '(.upload // 0) / 1000000')

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
    # InfluxDB timestamp
    # -----------------------------------------------------

    local TS
    TS=$(date +%s%N)

    # -----------------------------------------------------
    # InfluxDB line protocol
    #
    # IMPORTANT:
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
    # There is intentionally NO comma before ping.
    # The space separates tags from fields.
    # -----------------------------------------------------

    local LINE

    LINE="speedtest,host=${HOSTNAME_ESCAPED},box=${BOX_ESCAPED},interface=${INTERFACE_ESCAPED} ping=${PING},download=${DL},upload=${UL} ${TS}"

    echo "📤 Sending: $LINE"

    curl_influx "$LINE"
}

# =========================================================
# Main
# =========================================================

echo "🚀 Speedtest from $HOSTNAME → influxdb"
echo "🔧 Speedtest type: $SPEEDTEST_TYPE"

# ---------------------------------------------------------
# Determine Internet interface BEFORE running Speedtest
# ---------------------------------------------------------

check_internet_interface

ROUTE_RESULT=$?

if [[ "$ROUTE_RESULT" -eq 2 ]]; then

    END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))

    echo "🛑 Speedtest skipped: Internet is not using Wi-Fi"
    echo "🕐 End:   $END_DATETIME"
    echo "⏱️ Duration: ${DURATION}s"

    exit 0
fi

if [[ "$ROUTE_RESULT" -ne 0 ]]; then

    echo "❌ Unable to determine whether speedtest is allowed"

    exit 1
fi

# ---------------------------------------------------------
# Run Speedtest
# ---------------------------------------------------------

local_json=""

if [[ "$SPEEDTEST_TYPE" == "ookla" ]]; then

    echo "🚀 Running Ookla speedtest..."

    LOCAL_JSON=$(speedtest \
        --accept-license \
        --accept-gdpr \
        -f json 2>/dev/null)

elif [[ "$SPEEDTEST_TYPE" == "speedtest-cli" ]]; then

    echo "🚀 Running Debian speedtest-cli..."

    LOCAL_JSON=$(speedtest-cli \
        --json 2>/dev/null)

else

    echo "❌ FATAL: Unsupported Speedtest type"

    exit 1
fi

# ---------------------------------------------------------
# Check JSON
# ---------------------------------------------------------

if [[ -z "$LOCAL_JSON" ]]; then

    echo "❌ No JSON output"

    END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))

    echo "🕐 End:   $END_DATETIME"
    echo "⏱️ Duration: ${DURATION}s"
    echo "❌ Failed: $END_DATETIME"

    exit 1
fi

# Optional validation
if ! echo "$LOCAL_JSON" | jq -e . >/dev/null 2>&1; then

    echo "❌ Speedtest returned invalid JSON"

    exit 1
fi

# ---------------------------------------------------------
# Send result
# ---------------------------------------------------------

send "$LOCAL_JSON"

RESULT=$?

# =========================================================
# End datetime / execution duration
# =========================================================

END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

echo "🕐 End:   $END_DATETIME"
echo "⏱️ Duration: ${DURATION}s"

if [[ "$RESULT" -eq 0 ]]; then

    echo "✅ Complete: $END_DATETIME"

else

    echo "❌ Failed: $END_DATETIME"

fi

exit "$RESULT"
