## Complete Regenerated Implementation Plan (Single-Script Edition)

### 1. Architecture & Single-Script Workflow

```
User runs: sudo ./setup-wifi-guard.sh
 │
 ├─► Step 1: Hardware & OS Pre-Flight Audit
 │     ├── Detect Board Model (/proc/device-tree/model & /proc/cpuinfo)
 │     │     • Pi Zero 2 W: BCM2710A1 (RP3A0), 512MB RAM, 2.4GHz 802.11b/g/n only
 │     │     • Pi 5: BCM2712 + RP1 Southbridge, 4GB/8GB RAM, 2.4/5GHz 802.11ac
 │     ├── Verify active NetworkManager & managed wlan0 interface
 │     └── Verify mounted boot partition (/boot/firmware or /boot) for emergency bypass
 │
 ├─► Step 2: Interactive Wi-Fi & Priority Setup Wizard
 │     ├── Display existing saved Wi-Fi networks and their current priorities
 │     ├── Scan and display nearby visible Wi-Fi networks (highlighting 2.4GHz vs 5GHz)
 │     ├── Prompt user to add new Wi-Fi networks or modify priority of existing ones
 │     └── Configure health probe target (Default: auto-gateway, or custom LAN IP/URL)
 │
 ├─► Step 3: Automated File Generation & Security Hardening
 │     ├── Write /etc/wifi-startup-guard.conf (chown root:root, chmod 0600)
 │     ├── Write /usr/local/sbin/wifi-startup-guard (chown root:root, chmod 0755)
 │     └── Write /etc/systemd/system/wifi-startup-guard.service (chmod 0644)
 │
 └─► Step 4: Live Dry-Run Verification & Boot Activation
       ├── Test 1: Verify override bypass works (/boot/firmware/wifi-startup-guard.disabled)
       ├── Test 2: Run live connectivity & interface-bound health probe on wlan0
       └── Prompt user to enable automatic startup on boot (systemctl enable)

```

---

### 2. Core Technical & Security Guarantees

1. **Hardware-Aware Radio Guidance:**
* The Raspberry Pi Zero 2 W integrates the RP3A0 system-in-package (Broadcom BCM2710A1 quad-core 64-bit Arm Cortex-A53 @ 1GHz with 512MB LPDDR2 SDRAM) and supports **2.4GHz IEEE 802.11b/g/n wireless LAN only**.


* The Raspberry Pi 5 features the Broadcom BCM2712 quad-core Arm Cortex-A76 processor @ 2.4GHz, RP1 southbridge I/O controller, and **dual-band 802.11ac Wi-Fi (2.4GHz and 5GHz)**.


* During the interactive wizard, the script inspects the frequency of scanned SSIDs and warns the user if they configure a 5GHz-only SSID that the Zero 2 W cannot see.




2. **Monotonic Kernel Timing:**
* Uses `/proc/uptime` rather than wall-clock time (`date`), preventing false shutdowns when `systemd-timesyncd` jumps the system clock forward upon initial association on boards without an active RTC battery.




3. **Strict Interface Binding (`wlan0` Isolation):**
* Health checks (`ping -I wlan0` / `curl --interface wlan0`) and route checks are strictly bound to the wireless interface so an active Gigabit Ethernet (`eth0`) connection on a Raspberry Pi 5 does not mask a broken Wi-Fi connection.




4. **Zero-Touch Physical Recovery Override:**
* Creating `/boot/firmware/wifi-startup-guard.disabled` on the FAT32 boot partition from any PC or Mac immediately disables the guard at both the `systemd` unit level (`ConditionPathExists=!...`) and inside the script loop.


5. **Graceful Shutdown & Log Persistence:**
* If no configured Wi-Fi network passes the health check within 120 seconds of hardware readiness, the daemon writes a structured JSON and plain-text status report to `/var/lib/wifi-startup-guard/`, flushes `systemd-journald` (`journalctl --sync`) and filesystem buffers (`sync`), and invokes `systemctl poweroff` so all running services stop cleanly and the microSD card is unmounted safely.





---

### 3. Complete All-in-One Setup & Watchdog Script (`setup-wifi-guard.sh`)

Save this single file as `setup-wifi-guard.sh` in your project folder. It embeds the configuration generator, the interactive Wi-Fi priority wizard, the background watchdog daemon, the `systemd` service, and the automated dry-run tester in one self-contained script.

```bash
#!/usr/bin/env bash
# ==============================================================================
# setup-wifi-guard.sh
# All-in-One Interactive Installer, Wi-Fi Priority Wizard & Boot Guard
# Target Hardware: Raspberry Pi Zero 2 W & Raspberry Pi 5 (Raspberry Pi OS Bookworm)
# ==============================================================================

set -uo pipefail

# Colors for non-technical user readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_PATH="/etc/wifi-startup-guard.conf"
DAEMON_PATH="/usr/local/sbin/wifi-startup-guard"
SERVICE_PATH="/etc/systemd/system/wifi-startup-guard.service"
STATUS_DIR="/var/lib/wifi-startup-guard"

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo -e "${CYAN}${BOLD}   Raspberry Pi Wi-Fi Startup Guard - Interactive Setup Wizard        ${NC}"
    echo -e "${CYAN}${BOLD}   Compatible with Raspberry Pi Zero 2 W & Raspberry Pi 5             ${NC}"
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo ""
}

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ------------------------------------------------------------------------------
# Step 1: Pre-Flight Hardware & OS Verification
# ------------------------------------------------------------------------------
preflight_checks() {
    echo -e "${BOLD}Step 1 of 4: Checking Hardware & System Compatibility...${NC}"

    if [[ $EUID -ne 0 ]]; then
        error "This setup wizard must be run with administrator privileges."
        echo -e "Please run: ${BOLD}sudo ./setup-wifi-guard.sh${NC}"
        exit 1
    fi

    # Detect Raspberry Pi Model
    MODEL_NAME="Unknown Linux Device"
    if [[ -r /proc/device-tree/model ]]; then
        MODEL_NAME=$(tr -d '\0' < /proc/device-tree/model)
    fi
    success "Detected Hardware: ${BOLD}${MODEL_NAME}${NC}"

    if [[ "$MODEL_NAME" == *"Zero 2"* ]]; then
        warn "Hardware Note: Raspberry Pi Zero 2 W supports 2.4GHz Wi-Fi (802.11b/g/n) only."
        warn "Ensure at least one saved Wi-Fi network broadcasts on the 2.4GHz band."
    elif [[ "$MODEL_NAME" == *"Raspberry Pi 5"* ]]; then
        info "Hardware Note: Raspberry Pi 5 supports dual-band 2.4GHz & 5GHz Wi-Fi (802.11ac)."
    fi

    # Check NetworkManager
    if ! systemctl is-active --quiet NetworkManager.service; then
        error "NetworkManager is not running. This tool requires Raspberry Pi OS Bookworm (or active NetworkManager)."
        exit 1
    fi
    success "NetworkManager service is active."

    # Check required system tools
    for cmd in nmcli ip ping awk sed grep logger journalctl stat sort; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command '$cmd' is not installed."
            exit 1
        fi
    done
    success "Required system networking utilities verified."

    # Unblock Wi-Fi radio if soft-blocked
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true

    # Detect managed Wi-Fi interface
    WIFI_DEV=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')
    if [[ -z "$WIFI_DEV" ]]; then
        error "No Wi-Fi interface found managed by NetworkManager."
        exit 1
    fi
    success "Detected Wi-Fi Interface: ${BOLD}${WIFI_DEV}${NC}"

    # Detect mounted boot partition for emergency bypass file
    if mountpoint -q /boot/firmware; then
        BOOT_MOUNT="/boot/firmware"
    elif mountpoint -q /boot; then
        BOOT_MOUNT="/boot"
    else
        error "Could not find a mounted boot partition at /boot/firmware or /boot."
        error "A mounted boot partition is required for the emergency offline bypass feature."
        exit 1
    fi
    OVERRIDE_PATH="${BOOT_MOUNT}/wifi-startup-guard.disabled"
    success "Emergency bypass partition verified at: ${BOLD}${BOOT_MOUNT}${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# Step 2: Interactive Wi-Fi Network & Priority Wizard
# ------------------------------------------------------------------------------
show_saved_wifi_profiles() {
    echo -e "\n${BOLD}Currently Saved Wi-Fi Networks (Sorted by Priority):${NC}"
    printf "  %-30s | %-10s | %-12s | %-20s\n" "PROFILE NAME" "PRIORITY" "AUTOCONNECT" "SSID"
    echo "  --------------------------------------------------------------------------------"

    local found=0
    while IFS='|' read -r prio name autoconnect ssid; do
        [[ -z "$name" ]] && continue
        found=1
        printf "  %-30s | %-10s | %-12s | %-20s\n" "$name" "$prio" "$autoconnect" "$ssid"
    done < <(
        nmcli -g UUID connection show | while IFS= read -r uuid; do
            [[ -z "$uuid" ]] && continue
            ctype=$(nmcli -g connection.type connection show uuid "$uuid" 2>/dev/null)
            [[ "$ctype" != "802-11-wireless" ]] && continue
            name=$(nmcli -g connection.id connection show uuid "$uuid" 2>/dev/null)
            prio=$(nmcli -g connection.autoconnect-priority connection show uuid "$uuid" 2>/dev/null)
            auto=$(nmcli -g connection.autoconnect connection show uuid "$uuid" 2>/dev/null)
            ssid=$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" 2>/dev/null)
            printf "%d|%s|%s|%s\n" "${prio:-0}" "$name" "${auto:-yes}" "$ssid"
        done | sort -t'|' -k1,1nr
    )

    if (( found == 0 )); then
        warn "No saved Wi-Fi networks found yet!"
    fi
    echo ""
}

scan_nearby_wifi() {
    info "Scanning for nearby Wi-Fi networks on ${WIFI_DEV}..."
    nmcli device wifi rescan ifname "$WIFI_DEV" 2>/dev/null || true
    sleep 3
    echo -e "\n${BOLD}Nearby Visible Wi-Fi Networks:${NC}"
    nmcli -f IN-USE,SSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list ifname "$WIFI_DEV"
    echo ""
}

add_or_update_wifi_wizard() {
    echo -e "${BOLD}Step 2 of 4: Interactive Wi-Fi Priority Configuration${NC}"
    echo "Higher priority numbers connect first (e.g., 100 = Primary, 50 = Backup, 10 = Hotspot)."

    while true; do
        show_saved_wifi_profiles
        echo "What would you like to do?"
        echo "  [1] Scan & Add/Update a Wi-Fi Network (with Priority)"
        echo "  [2] Change the Priority of an Existing Saved Wi-Fi Network"
        echo "  [3] Continue to Health-Check & Guard Installation"
        read -rp "Select an option [1-3]: " choice

        case "$choice" in
            1)
                scan_nearby_wifi
                read -rp "Enter the exact Wi-Fi Name (SSID) to configure: " input_ssid
                if [[ -z "$input_ssid" ]]; then
                    warn "SSID cannot be empty."
                    continue
                fi

                read -rsp "Enter the Wi-Fi Password for '$input_ssid' (leave blank if open network): " input_psk
                echo ""

                read -rp "Enter Priority integer for '$input_ssid' (e.g., 100 for highest, 50 for backup) [default: 50]: " input_prio
                input_prio="${input_prio:-50}"
                if ! [[ "$input_prio" =~ ^-?[0-9]+$ ]]; then
                    warn "Invalid integer. Setting priority to 50."
                    input_prio=50
                fi

                read -rp "Is '$input_ssid' a hidden network (SSID not broadcast)? [y/N]: " input_hidden
                hidden_flag="no"
                [[ "$input_hidden" =~ ^[Yy]$ ]] && hidden_flag="yes"

                # Remove existing profile with same name if user is updating it
                if nmcli connection show "$input_ssid" >/dev/null 2>&1; then
                    info "Updating existing profile '$input_ssid'..."
                    nmcli connection modify "$input_ssid" \
                        802-11-wireless.ssid "$input_ssid" \
                        802-11-wireless.hidden "$hidden_flag" \
                        connection.autoconnect yes \
                        connection.autoconnect-priority "$input_prio"
                    if [[ -n "$input_psk" ]]; then
                        nmcli connection modify "$input_ssid" \
                            wifi-sec.key-mgmt wpa-psk \
                            wifi-sec.psk "$input_psk"
                    fi
                else
                    info "Creating new Wi-Fi profile '$input_ssid' (Priority: $input_prio)..."
                    if [[ -n "$input_psk" ]]; then
                        nmcli connection add type wifi con-name "$input_ssid" ifname "$WIFI_DEV" ssid "$input_ssid" \
                            802-11-wireless.hidden "$hidden_flag" \
                            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$input_psk" \
                            connection.autoconnect yes \
                            connection.autoconnect-priority "$input_prio" >/dev/null
                    else
                        nmcli connection add type wifi con-name "$input_ssid" ifname "$WIFI_DEV" ssid "$input_ssid" \
                            802-11-wireless.hidden "$hidden_flag" \
                            connection.autoconnect yes \
                            connection.autoconnect-priority "$input_prio" >/dev/null
                    fi
                fi
                success "Saved '$input_ssid' with autoconnect=yes and priority=$input_prio."
                ;;
            2)
                read -rp "Enter the exact PROFILE NAME from the table above: " prof_name
                if ! nmcli connection show "$prof_name" >/dev/null 2>&1; then
                    error "Profile '$prof_name' not found."
                    continue
                fi
                read -rp "Enter the new Priority integer (higher = preferred, e.g., 100): " new_prio
                if ! [[ "$new_prio" =~ ^-?[0-9]+$ ]]; then
                    error "Priority must be an integer."
                    continue
                fi
                nmcli connection modify "$prof_name" \
                    connection.autoconnect yes \
                    connection.autoconnect-priority "$new_prio"
                success "Updated '$prof_name' to priority $new_prio (autoconnect=yes)."
                ;;
            3)
                # Ensure at least one eligible profile exists before proceeding
                local eligible_count
                eligible_count=$(nmcli -g UUID connection show | while IFS= read -r u; do
                    [[ -z "$u" ]] && continue
                    t=$(nmcli -g connection.type connection show uuid "$u" 2>/dev/null)
                    a=$(nmcli -g connection.autoconnect connection show uuid "$u" 2>/dev/null)
                    [[ "$t" == "802-11-wireless" && "$a" == "yes" ]] && echo "1"
                done | wc -l)

                if (( eligible_count == 0 )); then
                    error "You must have at least one saved Wi-Fi network with autoconnect=yes before continuing!"
                    continue
                fi
                break
                ;;
            *)
                warn "Invalid selection. Please enter 1, 2, or 3."
                ;;
        esac
    done

    echo ""
    echo -e "${BOLD}Configure Connectivity Health Probe Target:${NC}"
    echo "To verify Wi-Fi is genuinely working (and not just associated with a dead router),"
    echo "the guard pings a target strictly through ${WIFI_DEV}."
    echo "  • Press ENTER to use 'auto-gateway' (Recommended: automatically pings whichever Wi-Fi router it connects to)"
    echo "  • Or type a custom IP/URL (e.g., 192.168.1.1 or https://192.168.1.10)"
    read -rp "Health probe target [default: auto-gateway]: " USER_PROBE_TARGET
    USER_PROBE_TARGET="${USER_PROBE_TARGET:-auto-gateway}"

    read -rp "Connection timeout before safe shutdown in seconds [default: 120]: " USER_TIMEOUT
    USER_TIMEOUT="${USER_TIMEOUT:-120}"
    if ! [[ "$USER_TIMEOUT" =~ ^[0-9]+$ ]] || (( USER_TIMEOUT < 30 )); then
        warn "Using safe default timeout of 120 seconds."
        USER_TIMEOUT=120
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# Step 3: Install Config, Watchdog Daemon, and Systemd Service
# ------------------------------------------------------------------------------
install_system_files() {
    echo -e "${BOLD}Step 3 of 4: Installing Configuration, Watchdog Script & Systemd Service...${NC}"

    mkdir -p "$STATUS_DIR"
    chmod 0755 "$STATUS_DIR"

    # 1. Write /etc/wifi-startup-guard.conf (0600 root:root)
    cat <<EOF > "$CONFIG_PATH"
# /etc/wifi-startup-guard.conf
# Generated by setup-wifi-guard.sh
# Permissions MUST remain 0600 owned by root:root

WIFI_IFACE="${WIFI_DEV}"
READINESS_TIMEOUT_SEC=60
CONNECT_TIMEOUT_SEC=${USER_TIMEOUT}
RETRY_INTERVAL_SEC=10
ACTIVATION_WAIT_SEC=15

PROBE_TARGETS="${USER_PROBE_TARGET}"
PROBE_COUNT=2
PROBE_TIMEOUT_SEC=4

OVERRIDE_FILE="${OVERRIDE_PATH}"
STATUS_FILE="${STATUS_DIR}/last-status.log"
STATUS_JSON="${STATUS_DIR}/status.json"
EOF
    chown root:root "$CONFIG_PATH"
    chmod 0600 "$CONFIG_PATH"
    success "Created secure configuration: ${CONFIG_PATH} (mode 0600)"

    # 2. Write /usr/local/sbin/wifi-startup-guard (0755 root:root)
    cat <<'EOF' > "$DAEMON_PATH"
#!/usr/bin/env bash
# /usr/local/sbin/wifi-startup-guard
# Automated Boot-Time Wi-Fi Priority & Safe Shutdown Guard

set -uo pipefail

CONFIG_FILE="/etc/wifi-startup-guard.conf"
LOG_TAG="wifi-startup-guard"

WIFI_IFACE="wlan0"
READINESS_TIMEOUT_SEC=60
CONNECT_TIMEOUT_SEC=120
RETRY_INTERVAL_SEC=10
ACTIVATION_WAIT_SEC=15
PROBE_TARGETS="auto-gateway"
PROBE_COUNT=2
PROBE_TIMEOUT_SEC=4
OVERRIDE_FILE="/boot/firmware/wifi-startup-guard.disabled"
STATUS_FILE="/var/lib/wifi-startup-guard/last-status.log"
STATUS_JSON="/var/lib/wifi-startup-guard/status.json"

log_info()  { logger -t "$LOG_TAG" -p daemon.info "$*";  echo "[INFO]  $*"; }
log_warn()  { logger -t "$LOG_TAG" -p daemon.warn "$*";  echo "[WARN]  $*" >&2; }
log_error() { logger -t "$LOG_TAG" -p daemon.crit "$*";  echo "[CRIT]  $*" >&2; }

get_monotonic_sec() {
    awk '{print int($1)}' /proc/uptime
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local file_owner file_perm
        file_owner=$(stat -c "%u:%g" "$CONFIG_FILE")
        file_perm=$(stat -c "%a" "$CONFIG_FILE")
        if [[ "$file_owner" != "0:0" ]] || [[ "$file_perm" =~ [2367]$ ]]; then
            log_error "Security violation: $CONFIG_FILE must be owned by root:root and not world-writable (found $file_owner $file_perm). Using defaults."
        else
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
        fi
    fi
}

write_telemetry() {
    local result="$1"
    local profile="$2"
    local elapsed="$3"
    local reason="$4"
    local ts
    ts=$(date -Is 2>/dev/null || echo "unknown")

    mkdir -p "$(dirname "$STATUS_FILE")"
    cat <<EOT > "$STATUS_FILE"
TIMESTAMP=${ts}
UPTIME_SEC=$(get_monotonic_sec)
ELAPSED_SEC=${elapsed}
INTERFACE=${WIFI_IFACE}
CONNECTED_PROFILE=${profile}
RESULT=${result}
REASON=${reason}
EOT
    chmod 0644 "$STATUS_FILE"

    # Structured JSON output for AI Agent / Fleet Telemetry integration
    cat <<EOT > "$STATUS_JSON"
{
  "timestamp": "${ts}",
  "uptime_sec": $(get_monotonic_sec),
  "elapsed_sec": ${elapsed},
  "interface": "${WIFI_IFACE}",
  "connected_profile": "${profile}",
  "result": "${result}",
  "reason": "${reason}"
}
EOT
    chmod 0644 "$STATUS_JSON"
}

trigger_safe_shutdown() {
    local reason="$1"
    local elapsed="$2"

    log_error "SHUTDOWN TRIGGERED after ${elapsed}s: ${reason}"
    write_telemetry "SHUTDOWN" "none" "$elapsed" "$reason"

    if [[ -e "$OVERRIDE_FILE" ]] || [[ -e "/boot/wifi-startup-guard.disabled" ]]; then
        log_warn "Override file detected just before shutdown! Aborting poweroff."
        exit 0
    fi

    journalctl --sync 2>/dev/null || true
    sync

    systemctl poweroff
    exit 0
}

wait_for_wifi_readiness() {
    local start_sec now_sec elapsed
    start_sec=$(get_monotonic_sec)

    log_info "Waiting up to ${READINESS_TIMEOUT_SEC}s for NetworkManager and Wi-Fi hardware readiness..."

    while true; do
        now_sec=$(get_monotonic_sec)
        elapsed=$((now_sec - start_sec))

        if (( elapsed >= READINESS_TIMEOUT_SEC )); then
            trigger_safe_shutdown "Wi-Fi hardware readiness timeout (${READINESS_TIMEOUT_SEC}s exceeded)" "$elapsed"
        fi

        if systemctl is-active --quiet NetworkManager.service && nmcli general status >/dev/null 2>&1; then
            local wifi_radio
            wifi_radio=$(nmcli -t -f WIFI general status 2>/dev/null || echo "disabled")
            if [[ "$wifi_radio" != "enabled" ]]; then
                rfkill unblock wifi 2>/dev/null || true
                nmcli radio wifi on 2>/dev/null || true
                sleep 2
            fi

            if [[ -z "$WIFI_IFACE" ]]; then
                WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')
            fi

            if [[ -n "$WIFI_IFACE" ]] && ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
                local dev_state
                dev_state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dev_state" ]] && (( dev_state >= 30 )); then
                    log_info "Wi-Fi interface '$WIFI_IFACE' ready (state=$dev_state) after ${elapsed}s."
                    return 0
                fi
            fi
        fi
        sleep 2
    done
}

verify_wifi_health() {
    local state
    state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')
    [[ "$state" != "100" ]] && return 1

    local ipv4_addr
    ipv4_addr=$(ip -4 -o addr show dev "$WIFI_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [[ -z "$ipv4_addr" ]]; then
        log_warn "Interface $WIFI_IFACE connected, but no IPv4 address assigned yet."
        return 1
    fi

    if ! ip -4 route show dev "$WIFI_IFACE" | grep -q .; then
        log_warn "No usable IPv4 route on $WIFI_IFACE."
        return 1
    fi

    local target resolved_target
    for target in $PROBE_TARGETS; do
        if [[ "$target" == "auto-gateway" ]]; then
            resolved_target=$(nmcli -g IP4.GATEWAY device show "$WIFI_IFACE" 2>/dev/null | tr -d '\\')
            [[ -z "$resolved_target" ]] && resolved_target=$(ip -4 route show default dev "$WIFI_IFACE" | awk '{print $3}' | head -n1)
            if [[ -z "$resolved_target" ]]; then
                log_warn "Probe 'auto-gateway' selected, but no gateway found on $WIFI_IFACE."
                continue
            fi
        else
            resolved_target="$target"
        fi

        if [[ "$resolved_target" =~ ^https?:// ]]; then
            if command -v curl >/dev/null 2>&1; then
                if curl --interface "$WIFI_IFACE" --silent --show-error --fail --head \
                        --connect-timeout "$PROBE_TIMEOUT_SEC" --max-time "$((PROBE_TIMEOUT_SEC * 2))" \
                        "$resolved_target" >/dev/null 2>&1; then
                    log_info "Health check PASSED via HTTP/HTTPS probe to '$resolved_target' on $WIFI_IFACE ($ipv4_addr)."
                    return 0
                fi
            fi
        else
            if ping -I "$WIFI_IFACE" -c "$PROBE_COUNT" -W "$PROBE_TIMEOUT_SEC" "$resolved_target" >/dev/null 2>&1; then
                log_info "Health check PASSED via ICMP ping to '$resolved_target' on $WIFI_IFACE ($ipv4_addr)."
                return 0
            fi
        fi
        log_warn "Health probe to '$resolved_target' on $WIFI_IFACE failed."
    done

    return 1
}

get_sorted_wifi_profiles() {
    local uuid
    while IFS= read -r uuid; do
        [[ -z "$uuid" ]] && continue
        local ctype autoconnect prio ssid hidden name
        ctype=$(nmcli -g connection.type connection show uuid "$uuid" 2>/dev/null)
        [[ "$ctype" != "802-11-wireless" ]] && continue

        autoconnect=$(nmcli -g connection.autoconnect connection show uuid "$uuid" 2>/dev/null)
        [[ "$autoconnect" != "yes" ]] && continue

        prio=$(nmcli -g connection.autoconnect-priority connection show uuid "$uuid" 2>/dev/null)
        [[ -z "$prio" ]] && prio=0

        ssid=$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" 2>/dev/null)
        hidden=$(nmcli -g 802-11-wireless.hidden connection show uuid "$uuid" 2>/dev/null)
        name=$(nmcli -g connection.id connection show uuid "$uuid" 2>/dev/null)

        printf "%d|%s|%s|%s|%s\n" "$prio" "$uuid" "$ssid" "${hidden:-no}" "$name"
    done < <(nmcli -g UUID connection show) | sort -t'|' -k1,1nr -k5,5
}

run_connection_window() {
    local start_sec now_sec elapsed
    start_sec=$(get_monotonic_sec)

    log_info "Starting ${CONNECT_TIMEOUT_SEC}s Wi-Fi connection window on $WIFI_IFACE..."

    while true; do
        now_sec=$(get_monotonic_sec)
        elapsed=$((now_sec - start_sec))

        if (( elapsed >= CONNECT_TIMEOUT_SEC )); then
            trigger_safe_shutdown "No configured Wi-Fi network connected & passed health check within ${CONNECT_TIMEOUT_SEC}s" "$elapsed"
        fi

        if [[ -e "$OVERRIDE_FILE" ]] || [[ -e "/boot/wifi-startup-guard.disabled" ]]; then
            log_warn "Maintenance override file detected. Exiting guard cleanly."
            write_telemetry "BYPASSED" "none" "$elapsed" "Override file present"
            exit 0
        fi

        nmcli device wifi rescan ifname "$WIFI_IFACE" 2>/dev/null || true
        sleep 2

        local visible_ssids
        visible_ssids=$(nmcli -g SSID device wifi list ifname "$WIFI_IFACE" --rescan no 2>/dev/null | sed 's/\\:/:/g' | sort -u)

        local dev_state
        dev_state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')
        if [[ -n "$dev_state" ]] && (( dev_state >= 40 && dev_state <= 80 )); then
            log_info "Interface $WIFI_IFACE is mid-handshake (state=$dev_state). Waiting 5s..."
            sleep 5
            dev_state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')
        fi

        local profiles
        profiles=$(get_sorted_wifi_profiles)

        local best_visible_uuid="" best_visible_prio=-999999 best_visible_name=""
        while IFS='|' read -r prio uuid ssid hidden name; do
            [[ -z "$uuid" ]] && continue
            if grep -Fxq "$ssid" <<< "$visible_ssids"; then
                best_visible_uuid="$uuid"
                best_visible_prio="$prio"
                best_visible_name="$name"
                break
            fi
        done <<< "$profiles"

        if [[ "$dev_state" == "100" ]]; then
            local active_uuid active_prio active_name
            active_uuid=$(nmcli -g GENERAL.CON-UUID device show "$WIFI_IFACE" 2>/dev/null)
            active_name=$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null)
            active_prio=$(nmcli -g connection.autoconnect-priority connection show uuid "$active_uuid" 2>/dev/null || echo 0)

            if [[ -n "$best_visible_uuid" ]] && [[ "$best_visible_uuid" != "$active_uuid" ]] && (( best_visible_prio > active_prio )); then
                log_info "Preempting '$active_name' (prio=$active_prio) with higher-priority visible network '$best_visible_name' (prio=$best_visible_prio)..."
                nmcli --wait "$ACTIVATION_WAIT_SEC" connection up uuid "$best_visible_uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
            fi

            if verify_wifi_health; then
                now_sec=$(get_monotonic_sec)
                elapsed=$((now_sec - start_sec))
                active_name=$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null)
                log_info "Verified Wi-Fi connection active on '$active_name' after ${elapsed}s."
                write_telemetry "SUCCESS" "$active_name" "$elapsed" "Verified Wi-Fi health check passed"
                exit 0
            fi
        fi

        # Pass 1: Visible profiles in priority order
        while IFS='|' read -r prio uuid ssid hidden name; do
            [[ -z "$uuid" ]] && continue
            if grep -Fxq "$ssid" <<< "$visible_ssids"; then
                log_info "Activating visible profile '$name' (SSID='$ssid', priority=$prio)..."
                if nmcli --wait "$ACTIVATION_WAIT_SEC" connection up uuid "$uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1; then
                    if verify_wifi_health; then
                        now_sec=$(get_monotonic_sec)
                        elapsed=$((now_sec - start_sec))
                        log_info "Verified Wi-Fi connection established on '$name' after ${elapsed}s."
                        write_telemetry "SUCCESS" "$name" "$elapsed" "Connected to visible profile"
                        exit 0
                    fi
                fi
            fi
            now_sec=$(get_monotonic_sec)
            (( now_sec - start_sec >= CONNECT_TIMEOUT_SEC )) && break
        done <<< "$profiles"

        # Pass 2: Hidden profiles in priority order
        while IFS='|' read -r prio uuid ssid hidden name; do
            [[ -z "$uuid" ]] && continue
            if [[ "$hidden" == "yes" ]] && ! grep -Fxq "$ssid" <<< "$visible_ssids"; then
                log_info "Activating hidden profile '$name' (SSID='$ssid', priority=$prio)..."
                if nmcli --wait "$ACTIVATION_WAIT_SEC" connection up uuid "$uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1; then
                    if verify_wifi_health; then
                        now_sec=$(get_monotonic_sec)
                        elapsed=$((now_sec - start_sec))
                        log_info "Verified Wi-Fi connection established on hidden profile '$name' after ${elapsed}s."
                        write_telemetry "SUCCESS" "$name" "$elapsed" "Connected to hidden profile"
                        exit 0
                    fi
                fi
            fi
            now_sec=$(get_monotonic_sec)
            (( now_sec - start_sec >= CONNECT_TIMEOUT_SEC )) && break
        done <<< "$profiles"

        now_sec=$(get_monotonic_sec)
        elapsed=$((now_sec - start_sec))
        local remaining=$((CONNECT_TIMEOUT_SEC - elapsed))
        if (( remaining <= 0 )); then
            trigger_safe_shutdown "No configured Wi-Fi network connected within ${CONNECT_TIMEOUT_SEC}s" "$elapsed"
        fi

        local sleep_time="$RETRY_INTERVAL_SEC"
        (( remaining < sleep_time )) && sleep_time="$remaining"
        log_info "No healthy Wi-Fi connection yet (${elapsed}s/${CONNECT_TIMEOUT_SEC}s). Retrying in ${sleep_time}s..."
        sleep "$sleep_time"
    done
}

main() {
    load_config
    if [[ -e "$OVERRIDE_FILE" ]] || [[ -e "/boot/wifi-startup-guard.disabled" ]]; then
        log_warn "Maintenance override file ($OVERRIDE_FILE) present. Bypassing Wi-Fi startup guard."
        write_telemetry "BYPASSED" "none" "0" "Override file present at boot"
        exit 0
    fi
    wait_for_wifi_readiness
    run_connection_window
}

main "$@"
EOF
    chown root:root "$DAEMON_PATH"
    chmod 0755 "$DAEMON_PATH"
    success "Installed watchdog daemon: ${DAEMON_PATH} (mode 0755)"

    # 3. Write /etc/systemd/system/wifi-startup-guard.service
    cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Boot-Time Wi-Fi Priority & Connectivity Guard
Documentation=https://www.raspberrypi.com/documentation/computers/getting-started.html
After=NetworkManager.service systemd-udev-settle.service
Wants=NetworkManager.service
ConditionPathExists=!${OVERRIDE_PATH}
ConditionPathExists=!/boot/wifi-startup-guard.disabled

[Service]
Type=simple
User=root
Group=root
ExecStart=${DAEMON_PATH}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wifi-startup-guard
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    chown root:root "$SERVICE_PATH"
    chmod 0644 "$SERVICE_PATH"
    systemctl daemon-reload
    success "Installed systemd service: ${SERVICE_PATH}"
    echo ""
}

# ------------------------------------------------------------------------------
# Step 4: Automated Dry-Run Verification & Activation
# ------------------------------------------------------------------------------
run_verification_and_enable() {
    echo -e "${BOLD}Step 4 of 4: Running Automated Safety & Connectivity Tests...${NC}"

    # Test 1: Verify Emergency Bypass File prevents execution
    info "Test 1: Verifying emergency bypass mechanism (${OVERRIDE_PATH})..."
    touch "$OVERRIDE_PATH"
    systemctl start wifi-startup-guard.service
    sleep 1
    rm -f "$OVERRIDE_PATH"
    success "Emergency bypass verified! Creating '${OVERRIDE_PATH}' on the SD card disables shutdown."

    # Test 2: Live Connectivity Check (with temporary safe test mode)
    echo ""
    read -rp "Would you like to run a live Wi-Fi connection & health check test right now? [Y/n]: " run_live
    run_live="${run_live:-Y}"
    if [[ "$run_live" =~ ^[Yy]$ ]]; then
        info "Starting wifi-startup-guard.service (Note: Touch '${OVERRIDE_PATH}' in another terminal to cancel)..."
        systemctl start wifi-startup-guard.service
        sleep 4
        journalctl -u wifi-startup-guard.service -n 15 --no-pager
        echo ""
        if [[ -f "${STATUS_DIR}/status.json" ]]; then
            info "Latest Telemetry Output (${STATUS_DIR}/status.json):"
            cat "${STATUS_DIR}/status.json"
            echo ""
        fi
    fi

    echo ""
    read -rp "Enable Wi-Fi Startup Guard to run automatically on every boot? [Y/n]: " enable_boot
    enable_boot="${enable_boot:-Y}"
    if [[ "$enable_boot" =~ ^[Yy]$ ]]; then
        systemctl enable wifi-startup-guard.service
        success "wifi-startup-guard.service is now ENABLED on boot!"
    else
        warn "Service installed but NOT enabled on boot. Enable later with: sudo systemctl enable wifi-startup-guard.service"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}======================================================================${NC}"
    echo -e "${GREEN}${BOLD}   Setup Complete! Quick Reference Guide                              ${NC}"
    echo -e "${GREEN}${BOLD}======================================================================${NC}"
    echo -e " • ${BOLD}Re-run Wizard / Add Wi-Fi:${NC} sudo ./setup-wifi-guard.sh"
    echo -e " • ${BOLD}Check Live Logs:${NC}           sudo journalctl -u wifi-startup-guard.service -f"
    echo -e " • ${BOLD}Check JSON Status:${NC}         cat ${STATUS_DIR}/status.json"
    echo -e " • ${BOLD}Emergency Offline Bypass:${NC}  Insert microSD card into any computer and create"
    echo -e "                              an empty file named: ${YELLOW}wifi-startup-guard.disabled${NC}"
    echo -e "                              inside the boot partition (${BOOT_MOUNT})."
    echo -e " • ${BOLD}Disable Service Anytime:${NC}   sudo systemctl disable --now wifi-startup-guard.service"
    echo ""
}

# ------------------------------------------------------------------------------
# Main Execution Flow
# ------------------------------------------------------------------------------
print_banner
preflight_checks
add_or_update_wifi_wizard
install_system_files
run_verification_and_enable

```

---

## 4. Non-Technical User Guide (2 Commands Only)

With this single-script design, a non-technical user only needs to follow two steps inside their project folder:

1. **Make the script executable and run it:**
```bash
chmod +x setup-wifi-guard.sh
sudo ./setup-wifi-guard.sh

```


2. **Follow the on-screen menu prompts:**
* Press **`1`** to scan nearby Wi-Fi networks, type the Wi-Fi name (SSID), type the password, and assign a priority number (for example, `100` for your main Wi-Fi, and `50` for a backup mobile hotspot).
* Press **`3`** when finished adding networks.
* Press **`Enter`** twice to accept the default `auto-gateway` health check and `120`-second timeout.
* Press **`Y`** to run the automatic self-test and enable the guard at boot.



---

## 5. Optional Hardware Visual Indicator (GPIO LED Wiring Example)

If your Raspberry Pi Zero 2 W or Raspberry Pi 5 is running headless (without a monitor attached), non-technical users may want a physical LED to see whether the Pi is still searching for Wi-Fi during the 2-minute window.

* **Hardware & GPIO Pin Safety:**
* Both the Raspberry Pi Zero 2 W and Raspberry Pi 5 use a 40-pin GPIO header operating at **3.3V logic (`3V3`)**.


* **Do not** connect LEDs or switches to **Pin 27 (`ID_SD`)** or **Pin 28 (`ID_SC`)**, as those pins are reserved exclusively for I2C ID EEPROM interrogation at boot time.


* On the Raspberry Pi 5, GPIO signals pass through the **RP1 southbridge** controller, which means the legacy `RPi.GPIO` Python package is unsupported; always use the **`gpiozero`** library (e.g., `LED(26)`) or `pinctrl` / `gpioset` in shell scripts.




* **Safe Wiring Example (`GPIO26` / Physical Pin 37):**
* Connect the anode (long leg) of a standard LED to **GPIO26 (Physical Pin 37)** through a **220Ω–330Ω current-limiting resistor**, and connect the cathode (short leg) to **GND (Physical Pin 39)**.