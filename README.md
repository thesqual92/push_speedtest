# Push Speedtest to InfluxDB

Bash script designed to run a Speedtest on Debian/Linux devices and push the results to an InfluxDB 1.x database.

The script supports both **64-bit ARM64** and **32-bit ARMHF** Raspberry Pi systems and automatically selects the appropriate Speedtest implementation:

- **ARM64** -> Ookla `speedtest`
- **ARMHF / 32-bit** -> Debian `speedtest-cli`

The script automatically detects the ISP/Internet connection (SSID) using several methods:

1. Direct Wi-Fi SSID detection
2. Cached SSID
3. Public IP / FQDN matching
4. Local IP / FQDN matching

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
```

the script uses:

```text
speedtest
```

If Ookla Speedtest is not installed, the script automatically attempts to install it.

### ARMHF / 32-bit

On 32-bit Raspberry Pi systems:

```text
armhf
```

the script uses Debian's:

```text
speedtest-cli
```

If it is not installed, the script automatically runs:

```bash
sudo apt update
sudo apt install -y speedtest-cli
```

This is particularly useful for Raspberry Pi Zero devices running 32-bit Raspberry Pi OS / Debian Trixie.

---

## Requirements

The script is designed for Debian-based systems, including:

- Debian Trixie ARM64
- Raspberry Pi OS / Debian Trixie ARM64
- Raspberry Pi OS / Debian Trixie ARMHF
- Raspberry Pi 4B
- Raspberry Pi Zero / Zero W

Required commands:

- `bash`
- `curl`
- `jq`
- `ip`
- `getent`
- `python3`
- `iw` (optional, required for direct Wi-Fi SSID detection)
- Ookla `speedtest` on ARM64
- Debian `speedtest-cli` on ARMHF

The appropriate Speedtest implementation is installed automatically if it is missing.

Install the other dependencies with:

```bash
sudo apt update
sudo apt install -y curl jq iproute2 python3 iw
```

For 32-bit ARMHF, `speedtest-cli` is installed automatically by the script.

---

## Configuration

The script expects an `isp.cfg` file in the same directory as `push_speedtest.sh`.

Example:

```text
# DETECTED_SSID=Livebox-XXX
Livebox-XXX=FQDN=192.168.1.10
```

The format is:

```text
SSID=FQDN=LOCAL_IP
```

For example:

```text
Livebox-D8B0=livebox-d8b0.example.com=192.168.1.1
Livebox-D330=livebox-d330.example.com=192.168.1.1
Freebox=freebox.example.com=192.168.1.254
```

---

## SSID detection

The script first attempts to detect the currently connected Wi-Fi SSID directly:

```bash
iw dev wlan0 link
```

If an SSID is detected, it is used directly.

If Wi-Fi SSID detection is not available, the script uses the public IPv4 address returned by Speedtest and compares it with the FQDNs configured in `isp.cfg`.

The detection sequence is:

```text
Wi-Fi SSID
    |
    v
Cached SSID validation
    |
    v
Public IP / FQDN matching
    |
    v
Local IP / FQDN matching
    |
    v
SSID not found -> Speedtest result is not sent
```

---

## Cached SSID

Once an ISP/SSID has been successfully identified using DNS/IP matching, the script stores it at the beginning of `isp.cfg`:

```text
# DETECTED_SSID=Livebox-XXX
```

On the next execution, the cached SSID is checked first.

If it is no longer valid, the script automatically performs a full detection.

---

## InfluxDB

The script sends data to an InfluxDB 1.x database named:

```text
speedtest
```

The InfluxDB hostname is:

```text
influxdb
```

The password is read from:

```text
/etc/speedtest/influxdb_pass
```

The script sends data using InfluxDB Line Protocol.

Example:

```text
speedtest,host=pizero,box=Livebox-XXX,interface=Livebox-XXX ping=12.3,download=92.5,upload=18.7 1755510302000000000
```

The fields are:

- `ping`
- `download`
- `upload`

The tags are:

- `host`
- `box`
- `interface`

---

## Public IP detection

The public IPv4 address is extracted directly from the Speedtest JSON result.

For ARMHF / `speedtest-cli`:

```text
.client.ip
```

For ARM64 / Ookla Speedtest:

```text
.interface.externalIp
```

This avoids using an external service such as:

```text
https://api.ipify.org
```

The public IP detected by Speedtest is therefore the IP associated with the actual connection used for the speed test.

---

## Execution logging

The script records the start and end time of each execution.

Example:

```text
Start: 2026-08-18 11:46:32
...
End:   2026-08-18 11:47:17
Duration: 46s
Complete: 2026-08-18 11:47:17
```

If the execution fails:

```text
End:   2026-08-18 11:47:17
Duration: 46s
Failed: 2026-08-18 11:47:17
```

This makes the script execution time easy to identify in cron/system logs.

---

## Running manually

Make the script executable:

```bash
chmod +x push_speedtest.sh
```

Run it with:

```bash
sudo ./push_speedtest.sh
```

Example on a Pi Zero:

```text
Start: 2026-08-18 11:46:32
Architecture: armhf
Using Debian speedtest-cli: /usr/bin/speedtest-cli
Speedtest from pizero -> influxdb
Speedtest type: speedtest-cli
...
End:   2026-08-18 11:47:17
Duration: 46s
Complete: 2026-08-18 11:47:17
```

Example on a Pi 4B:

```text
Start: 2026-08-18 11:45:02
Architecture: arm64
Using Ookla speedtest: /usr/bin/speedtest
Speedtest from pi4b -> influxdb
Speedtest type: ookla
...
End:   2026-08-18 11:45:35
Duration: 33s
Complete: 2026-08-18 11:45:35
```

---

## Automatic installation

### ARMHF / 32-bit

If `speedtest-cli` is not installed, the script automatically executes:

```bash
sudo apt update
sudo apt install -y speedtest-cli
```

The installed executable is then verified:

```bash
command -v speedtest-cli
```

### ARM64 / 64-bit

If Ookla `speedtest` is not installed, the script automatically attempts to configure the Ookla repository and install:

```bash
sudo apt install -y speedtest
```

The installed executable is then verified:

```bash
command -v speedtest
```

---

## Important note about Debian Trixie ARM64

The Ookla installation method uses the Ookla/packagecloud repository when `speedtest` is missing.

On some Debian/Raspberry Pi Trixie configurations, the repository may not provide a matching `raspbian/trixie` distribution and can therefore return:

```text
404 Not Found
```

If `speedtest` is already installed, the script does not attempt to reinstall it.

For ARMHF / 32-bit Trixie, the script uses the Debian repository package:

```text
speedtest-cli
```

which is available directly through `apt`.

---

## InfluxDB connection errors

The script provides specific diagnostic messages when it cannot send data to InfluxDB.

Examples:

```text
DNS ERROR: Cannot resolve influxdb
```

```text
CONNECT ERROR: Cannot reach influxdb:8086
```

```text
TIMEOUT: influxdb:8086
```

```text
HTTP ERROR: 401
```

A successful InfluxDB write returns:

```text
SUCCESS HTTP: 204
```

---

## Exit status

The script returns:

```text
0
```

when the Speedtest was successfully completed and the result was successfully sent to InfluxDB.

It returns:

```text
1
```

when an error occurs, for example:

- Missing `isp.cfg`
- Speedtest installation failure
- Speedtest execution failure
- Missing public IP
- ISP/SSID detection failure
- Invalid Speedtest JSON
- InfluxDB connection failure
- InfluxDB HTTP error

This makes the script suitable for execution from cron or other monitoring systems.

---

## Example directory

A typical installation looks like:

```text
~/scripts/speedtest/
├── push_speedtest.sh
└── isp.cfg
```

The InfluxDB password is stored separately:

```text
/etc/speedtest/influxdb_pass
```

Add the script to crontab (root)

```text
*/5 * * * * /opt/speedtest-stack/scripts/push_speedtest.sh >> /var/log/speedtest_cron.log 2>&1
```

## License

Personal / internal use.
