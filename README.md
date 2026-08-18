# Push Speedtest to InfluxDB

Bash script designed to run a Speedtest on Debian/Linux devices and push the results to an InfluxDB 1.x database.

The script supports both **64-bit ARM64** and **32-bit ARMHF** Raspberry Pi systems and automatically selects the appropriate Speedtest implementation:

- **ARM64** → Ookla `speedtest`
- **ARMHF / 32-bit** → Debian `speedtest-cli`

The script automatically detects the ISP/Internet connection (SSID) using several methods:

1. Direct Wi-Fi SSID detection
2. Cached SSID
3. Public IP / FQDN matching
4. Local device IP / FQDN matching

This allows the same script to run on multiple devices connected to different Internet connections.

---

## Features

- Automatically detects the system architecture.
- Supports **ARM64 and ARMHF / 32-bit** systems.
- Automatically installs **Ookla Speedtest** on ARM64 if it is not installed.
- Automatically installs Debian **`speedtest-cli`** on ARMHF if it is not installed.
- Runs Speedtest in JSON format.
- Extracts the public IPv4 address directly from the Speedtest result.
- Does not require an external public-IP service such as `api.ipify.org`.
- Extracts:
  - Ping latency
  - Download speed
  - Upload speed
- Detects the active ISP/connection.
- Supports Wi-Fi SSID detection using `iw`.
- Supports multiple FQDNs for the same SSID.
- Supports public IP matching.
- Supports private/local IP matching.
- Supports both single IP addresses and CIDR networks.
- Caches the last detected SSID in `isp.cfg`.
- Automatically falls back to DNS/IP detection if the cached SSID is no longer valid.
- Sends data to InfluxDB using the Line Protocol.
- Records script start and end timestamps.
- Displays total script execution duration.
- Provides detailed diagnostic output.

---

## Speedtest implementations

The script automatically selects the Speedtest implementation based on the Debian architecture.

### ARM64

On 64-bit systems:

```text
arm64
