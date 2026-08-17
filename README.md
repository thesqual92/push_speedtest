# Push Speedtest to InfluxDB

Bash script designed to run an Ookla Speedtest on Debian/Linux devices and push the results to an InfluxDB 1.x database.

The script automatically detects the ISP/connection (SSID) using several methods:

1. Wi-Fi SSID detection
2. Cached SSID
3. Public IP / FQDN matching
4. Local device IP / FQDN matching

This allows the same script to run on multiple devices connected to different Internet connections.

---

## Features

- Automatically installs the Ookla Speedtest CLI if it is not installed.
- Runs Speedtest in JSON format.
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
- Provides detailed diagnostic output.

---

## Requirements

The script is designed for Debian-based systems, including Debian Trixie ARM64.

Required commands:

- `bash`
- `curl`
- `jq`
- `ip`
- `getent`
- `ping`
- `python3`
- `iw` (optional, required for direct Wi-Fi SSID detection)
- Ookla `speedtest`

The script automatically installs `speedtest` if it is missing.

Install the other dependencies with:

```bash
sudo apt update
sudo apt install -y curl jq iproute2 iputils-ping python3 iw
```


## Configuration

The script expects an isp.cfg file in the same directory as push_speedtest.sh.

Example:
```bash
#DETECTED_SSID=Livebox-XXX
Livebox-XXX=FQDN=192.168.1.10
```
