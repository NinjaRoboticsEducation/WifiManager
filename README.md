# Raspberry Pi Wi-Fi Startup Guard

Automatic Wi-Fi connection management and safe shutdown guard for **Raspberry Pi Zero 2 W** and **Raspberry Pi 5** running Raspberry Pi OS Bookworm.

## What It Does

When your Raspberry Pi boots:

1. **Auto-connects** to the highest-priority configured Wi-Fi network
2. **Scans and retries** for up to 2 minutes if no known network is available
3. **Safely shuts down** the system if no connection is established within the timeout
4. **Verifies real connectivity** by pinging the router (not just Wi-Fi association)

## Hardware Support

| Feature | Pi Zero 2 W | Pi 5 |
|---|---|---|
| Processor | BCM2710A1 (RP3A0) | BCM2712 + RP1 |
| Wi-Fi Bands | 2.4 GHz only | 2.4 GHz + 5 GHz |
| Auto-detected | ✔ | ✔ |
| Band warnings | ✔ (warns about 5 GHz SSIDs) | N/A |

## Quick Start (2 Commands)

```bash
chmod +x setup-wifi-guard.sh
sudo ./setup-wifi-guard.sh
```

Then follow the on-screen wizard:
- Press **1** to scan and add Wi-Fi networks with priorities
- Press **3** when done adding networks
- Press **Enter** to accept default health check settings
- Press **Y** to enable the guard on boot

## How Priorities Work

Networks are tried in descending priority order (highest number first):

| Priority | Use Case |
|---|---|
| 100 | Primary home/office Wi-Fi |
| 50 | Backup network |
| 10 | Emergency mobile hotspot |

If a higher-priority network becomes visible while connected to a lower-priority one, the guard will automatically switch.

## Emergency Recovery

If the guard shuts down your Pi because no Wi-Fi is available:

1. Remove the microSD card from the Pi
2. Insert it into any computer (Mac, Windows, Linux)
3. Open the **boot** partition (FAT32, readable by any OS)
4. Create an empty file named **`wifi-startup-guard.disabled`**
5. Reinsert the card and power on — the guard is bypassed

Delete the file when you've fixed your Wi-Fi to re-enable the guard.

## System Files

| File | Purpose |
|---|---|
| `/etc/wifi-startup-guard.conf` | Configuration (timeout, probe target, interface) |
| `/usr/local/sbin/wifi-startup-guard` | Watchdog daemon (runs at boot) |
| `/etc/systemd/system/wifi-startup-guard.service` | Systemd service unit |
| `/var/lib/wifi-startup-guard/status.json` | Last-run telemetry (JSON) |
| `/var/lib/wifi-startup-guard/last-status.log` | Last-run telemetry (plain text) |

## Common Commands

```bash
# Re-run the setup wizard (add/change Wi-Fi networks)
sudo ./setup-wifi-guard.sh

# Check live logs
sudo journalctl -u wifi-startup-guard.service -f

# Check last status
cat /var/lib/wifi-startup-guard/status.json

# Disable the service
sudo systemctl disable --now wifi-startup-guard.service

# Re-enable the service
sudo systemctl enable wifi-startup-guard.service
```

## Security

- Configuration file is `0600 root:root` (only root can read)
- Daemon validates config ownership and permissions before loading
- Health probes are strictly bound to the Wi-Fi interface (`ping -I wlan0`)
- Uses monotonic kernel time (`/proc/uptime`) to avoid NTP clock-jump issues
- Emergency bypass works at both systemd (`ConditionPathExists`) and script level

## Requirements

- Raspberry Pi OS Bookworm (or any Linux with NetworkManager)
- NetworkManager active and managing the Wi-Fi interface
- Standard utilities: `nmcli`, `ip`, `ping`, `awk`, `sed`, `grep`, `logger`, `journalctl`, `rfkill`

## Telemetry Output

After each boot, the guard writes `/var/lib/wifi-startup-guard/status.json`:

```json
{
  "timestamp": "2024-01-15T08:30:45+09:00",
  "uptime_sec": 42,
  "elapsed_sec": 12,
  "interface": "wlan0",
  "connected_profile": "MyHomeWiFi",
  "result": "SUCCESS",
  "reason": "Verified Wi-Fi health check passed"
}
```

Possible `result` values: `SUCCESS`, `SHUTDOWN`, `BYPASSED`.

## License

Part of the NinjaRoboticsEducationPlatform project.

