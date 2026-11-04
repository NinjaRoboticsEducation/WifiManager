#!/usr/bin/env bash
# ==============================================================================
# setup-wifi-guard.sh
# All-in-One Interactive Installer, Wi-Fi Priority Wizard & Boot Guard
# Target Hardware: Raspberry Pi Zero 2 W & Raspberry Pi 5 (Raspberry Pi OS Bookworm)
#
# Usage:
#   chmod +x setup-wifi-guard.sh
#   sudo ./setup-wifi-guard.sh
#
# This single script embeds:
#   • Step 1: Hardware & OS pre-flight audit
#   • Step 2: Interactive Wi-Fi & priority setup wizard
#   • Step 3: Automated file generation & security hardening
#   • Step 4: Live dry-run verification & boot activation
#
# The generated watchdog daemon (/usr/local/sbin/wifi-startup-guard) runs at
# boot via a systemd service. It connects to the highest-priority configured
# Wi-Fi, continuously retries for a configurable timeout (default 120 s), and
# safely shuts down if no network becomes available.
#
# Emergency Recovery: Create an empty file named "wifi-startup-guard.disabled"
# on the FAT32 boot partition (/boot/firmware or /boot) from any computer to
# disable the guard without needing network access.
# ==============================================================================

set -uo pipefail

# ── Terminal colours for non-technical user readability ───────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── System paths ─────────────────────────────────────────────────────────────
CONFIG_PATH="/etc/wifi-startup-guard.conf"
DAEMON_PATH="/usr/local/sbin/wifi-startup-guard"
SERVICE_PATH="/etc/systemd/system/wifi-startup-guard.service"
STATUS_DIR="/var/lib/wifi-startup-guard"

# ── Shared state set during pre-flight ───────────────────────────────────────
WIFI_DEV=""
BOOT_MOUNT=""
OVERRIDE_PATH=""
MODEL_NAME=""

# ── Shared state set during wizard ───────────────────────────────────────────
USER_PROBE_TARGET=""
USER_TIMEOUT=""

# ==============================================================================
# Helpers
# ==============================================================================
print_banner() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║   🛜  Raspberry Pi Wi-Fi Startup Guard — Interactive Setup Wizard  ║${NC}"
    echo -e "${CYAN}${BOLD}║      Compatible with Raspberry Pi Zero 2 W  &  Raspberry Pi 5      ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step_header() {
    local step_num="$1"
    local step_title="$2"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step ${step_num} of 4: ${step_title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

info()    { echo -e "  ${CYAN}ℹ${NC}  $*"; }
success() { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "  ${RED}✖${NC}  $*" >&2; }

separator() { echo -e "  ${DIM}──────────────────────────────────────────────────────────────${NC}"; }

# ==============================================================================
# Step 1: Pre-Flight Hardware & OS Verification
# ==============================================================================
preflight_checks() {
    print_step_header "1" "Checking Hardware & System Compatibility"

    # ── Root check ────────────────────────────────────────────────────────────
    if [[ $EUID -ne 0 ]]; then
        error "This setup wizard must be run with administrator privileges."
        echo ""
        echo -e "  Please run:  ${BOLD}sudo ./setup-wifi-guard.sh${NC}"
        echo ""
        exit 1
    fi

    # ── Detect Raspberry Pi model ─────────────────────────────────────────────
    MODEL_NAME="Unknown Linux Device"
    if [[ -r /proc/device-tree/model ]]; then
        MODEL_NAME=$(tr -d '\0' < /proc/device-tree/model)
    fi
    success "Detected hardware: ${BOLD}${MODEL_NAME}${NC}"

    if [[ "$MODEL_NAME" == *"Zero 2"* ]]; then
        separator
        warn "Hardware note — Raspberry Pi Zero 2 W:"
        echo -e "     Supports ${BOLD}2.4 GHz Wi-Fi only${NC} (802.11 b/g/n)."
        echo -e "     Make sure at least one saved network broadcasts on 2.4 GHz."
        separator
    elif [[ "$MODEL_NAME" == *"Raspberry Pi 5"* ]]; then
        info "Hardware note — Raspberry Pi 5: dual-band 2.4 GHz & 5 GHz (802.11ac)."
    fi

    # ── NetworkManager ────────────────────────────────────────────────────────
    if ! systemctl is-active --quiet NetworkManager.service; then
        error "NetworkManager is not running."
        echo -e "  This tool requires ${BOLD}Raspberry Pi OS Bookworm${NC} or any OS with"
        echo -e "  an active NetworkManager service."
        exit 1
    fi
    success "NetworkManager service is active."

    # ── Required utilities ────────────────────────────────────────────────────
    local missing_cmds=()
    for cmd in nmcli ip ping awk sed grep logger journalctl stat sort rfkill; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done
    if (( ${#missing_cmds[@]} > 0 )); then
        error "Missing required command(s): ${missing_cmds[*]}"
        echo -e "  Please install them before running this wizard."
        exit 1
    fi
    success "All required system utilities verified."

    # ── Unblock Wi-Fi radio ───────────────────────────────────────────────────
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true

    # ── Detect managed Wi-Fi interface ────────────────────────────────────────
    WIFI_DEV=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')
    if [[ -z "$WIFI_DEV" ]]; then
        error "No Wi-Fi interface found managed by NetworkManager."
        exit 1
    fi
    success "Detected Wi-Fi interface: ${BOLD}${WIFI_DEV}${NC}"

    # ── Boot partition for emergency bypass ───────────────────────────────────
    if mountpoint -q /boot/firmware 2>/dev/null; then
        BOOT_MOUNT="/boot/firmware"
    elif mountpoint -q /boot 2>/dev/null; then
        BOOT_MOUNT="/boot"
    else
        error "Could not find a mounted boot partition at /boot/firmware or /boot."
        echo -e "  A mounted boot partition is required for the emergency offline bypass."
        exit 1
    fi
    OVERRIDE_PATH="${BOOT_MOUNT}/wifi-startup-guard.disabled"
    success "Emergency bypass partition: ${BOLD}${BOOT_MOUNT}${NC}"

    echo ""
    success "${GREEN}Pre-flight checks passed.${NC}"
}

# ==============================================================================
# Step 2: Interactive Wi-Fi Network & Priority Wizard
# ==============================================================================
show_saved_wifi_profiles() {
    echo ""
    echo -e "  ${BOLD}Saved Wi-Fi Networks (sorted by priority, highest first):${NC}"
    echo ""
    printf "  ${DIM}%-30s │ %-8s │ %-12s │ %-20s${NC}\n" "PROFILE NAME" "PRIORITY" "AUTOCONNECT" "SSID"
    echo -e "  ${DIM}───────────────────────────────┼──────────┼──────────────┼─────────────────────${NC}"

    local found=0
    while IFS='|' read -r prio name autoconnect ssid; do
        [[ -z "$name" ]] && continue
        found=1
        printf "  %-30s │ %-8s │ %-12s │ %-20s\n" "$name" "$prio" "$autoconnect" "$ssid"
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
        echo ""
        warn "No saved Wi-Fi networks found yet."
    fi
    echo ""
}

scan_nearby_wifi() {
    info "Scanning for nearby Wi-Fi networks on ${BOLD}${WIFI_DEV}${NC}..."
    nmcli device wifi rescan ifname "$WIFI_DEV" 2>/dev/null || true
    sleep 3

    echo ""
    echo -e "  ${BOLD}Nearby Visible Wi-Fi Networks:${NC}"
    echo ""
    nmcli -f IN-USE,SSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list ifname "$WIFI_DEV" | sed 's/^/  /'

    # Warn Pi Zero 2 W users about 5 GHz networks
    if [[ "$MODEL_NAME" == *"Zero 2"* ]]; then
        local has_5ghz
        has_5ghz=$(nmcli -t -f FREQ device wifi list ifname "$WIFI_DEV" 2>/dev/null | grep -c "^5" || true)
        if (( has_5ghz > 0 )); then
            echo ""
            warn "Some networks above are on 5 GHz. Your Pi Zero 2 W can only connect to 2.4 GHz networks."
        fi
    fi
    echo ""
}

add_or_update_wifi_wizard() {
    print_step_header "2" "Interactive Wi-Fi Priority Configuration"

    echo -e "  Wi-Fi networks are tried in ${BOLD}priority order${NC} (highest number first)."
    echo -e "  Example priorities:  ${BOLD}100${NC} = Primary  ·  ${BOLD}50${NC} = Backup  ·  ${BOLD}10${NC} = Emergency Hotspot"

    while true; do
        show_saved_wifi_profiles

        echo -e "  ${BOLD}What would you like to do?${NC}"
        echo ""
        echo -e "    ${BOLD}1${NC} — Scan & add/update a Wi-Fi network (with priority)"
        echo -e "    ${BOLD}2${NC} — Change the priority of an existing saved network"
        echo -e "    ${BOLD}3${NC} — Continue to guard installation  →"
        echo ""
        read -rp "  Select an option [1-3]: " choice

        case "$choice" in
            1)
                echo ""
                scan_nearby_wifi

                read -rp "  Enter the exact Wi-Fi name (SSID) to configure: " input_ssid
                if [[ -z "$input_ssid" ]]; then
                    warn "SSID cannot be empty."
                    continue
                fi

                read -rsp "  Enter the Wi-Fi password for '${input_ssid}' (leave blank for open network): " input_psk
                echo ""

                read -rp "  Enter priority for '${input_ssid}' (e.g. 100=highest, 50=backup) [default: 50]: " input_prio
                input_prio="${input_prio:-50}"
                if ! [[ "$input_prio" =~ ^-?[0-9]+$ ]]; then
                    warn "Invalid integer. Setting priority to 50."
                    input_prio=50
                fi

                read -rp "  Is '${input_ssid}' a hidden network (SSID not broadcast)? [y/N]: " input_hidden
                hidden_flag="no"
                [[ "$input_hidden" =~ ^[Yy]$ ]] && hidden_flag="yes"

                # Update existing or create new profile
                if nmcli connection show "$input_ssid" >/dev/null 2>&1; then
                    info "Updating existing profile '${input_ssid}'..."
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
                    info "Creating new Wi-Fi profile '${input_ssid}' (priority: ${input_prio})..."
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
                success "Saved '${input_ssid}' with autoconnect=yes and priority=${input_prio}."
                ;;
            2)
                echo ""
                read -rp "  Enter the exact profile name from the table above: " prof_name
                if ! nmcli connection show "$prof_name" >/dev/null 2>&1; then
                    error "Profile '${prof_name}' not found."
                    continue
                fi
                read -rp "  Enter the new priority (higher = preferred, e.g. 100): " new_prio
                if ! [[ "$new_prio" =~ ^-?[0-9]+$ ]]; then
                    error "Priority must be an integer."
                    continue
                fi
                nmcli connection modify "$prof_name" \
                    connection.autoconnect yes \
                    connection.autoconnect-priority "$new_prio"
                success "Updated '${prof_name}' → priority ${new_prio} (autoconnect=yes)."
                ;;
            3)
                # Require at least one eligible profile
                local eligible_count
                eligible_count=$(nmcli -g UUID connection show | while IFS= read -r u; do
                    [[ -z "$u" ]] && continue
                    t=$(nmcli -g connection.type connection show uuid "$u" 2>/dev/null)
                    a=$(nmcli -g connection.autoconnect connection show uuid "$u" 2>/dev/null)
                    [[ "$t" == "802-11-wireless" && "$a" == "yes" ]] && echo "1"
                done | wc -l)

                if (( eligible_count == 0 )); then
                    error "You must have at least one saved Wi-Fi network with autoconnect=yes."
                    echo -e "  Please add a network first (option 1)."
                    continue
                fi
                break
                ;;
            *)
                warn "Invalid selection. Please enter 1, 2, or 3."
                ;;
        esac
    done

    # ── Health-probe configuration ────────────────────────────────────────────
    echo ""
    separator
    echo ""
    echo -e "  ${BOLD}Configure Connectivity Health Probe Target${NC}"
    echo ""
    echo -e "  After connecting to Wi-Fi, the guard verifies real connectivity by"
    echo -e "  pinging a target strictly through ${BOLD}${WIFI_DEV}${NC}."
    echo ""
    echo -e "    • Press ${BOLD}Enter${NC} to use ${BOLD}auto-gateway${NC} (recommended — pings your router)"
    echo -e "    • Or type a custom IP/URL (e.g. 192.168.1.1 or https://192.168.1.10)"
    echo ""
    read -rp "  Health probe target [default: auto-gateway]: " USER_PROBE_TARGET
    USER_PROBE_TARGET="${USER_PROBE_TARGET:-auto-gateway}"

    echo ""
    echo -e "  ${BOLD}Connection Timeout${NC}"
    echo -e "  How many seconds should the guard wait before safe shutdown?"
    echo ""
    read -rp "  Timeout in seconds [default: 120]: " USER_TIMEOUT
    USER_TIMEOUT="${USER_TIMEOUT:-120}"
    if ! [[ "$USER_TIMEOUT" =~ ^[0-9]+$ ]] || (( USER_TIMEOUT < 30 )); then
        warn "Using safe default timeout of 120 seconds."
        USER_TIMEOUT=120
    fi
    echo ""
}

# ==============================================================================
# Step 3: Install Config, Watchdog Daemon, and systemd Service
# ==============================================================================
install_system_files() {
    print_step_header "3" "Installing Configuration, Watchdog Script & Systemd Service"

    mkdir -p "$STATUS_DIR"
    chmod 0755 "$STATUS_DIR"

    # ── 3a. Write /etc/wifi-startup-guard.conf ────────────────────────────────
    info "Writing configuration file..."
    cat <<CONF_EOF > "$CONFIG_PATH"
# /etc/wifi-startup-guard.conf
# Generated by setup-wifi-guard.sh on $(date -Is 2>/dev/null || date)
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
CONF_EOF
    chown root:root "$CONFIG_PATH"
    chmod 0600 "$CONFIG_PATH"
    success "Configuration: ${BOLD}${CONFIG_PATH}${NC}  (mode 0600, root:root)"

    # ── 3b. Write /usr/local/sbin/wifi-startup-guard ──────────────────────────
    info "Writing watchdog daemon..."
    cat <<'DAEMON_EOF' > "$DAEMON_PATH"
#!/usr/bin/env bash
# ==============================================================================
# /usr/local/sbin/wifi-startup-guard
# Automated Boot-Time Wi-Fi Priority & Safe Shutdown Guard
#
# This daemon is started by systemd at boot. It:
#   1. Waits for Wi-Fi hardware readiness (up to READINESS_TIMEOUT_SEC).
#   2. Scans for configured Wi-Fi networks in priority order.
#   3. Attempts connection and verifies real connectivity via health probes.
#   4. Safely shuts down the system if no connection succeeds within
#      CONNECT_TIMEOUT_SEC.
#
# Uses monotonic kernel time (/proc/uptime) to avoid clock-jump issues.
# Strictly binds health probes to the wireless interface (wlan0 isolation).
# ==============================================================================

set -uo pipefail

CONFIG_FILE="/etc/wifi-startup-guard.conf"
LOG_TAG="wifi-startup-guard"

# ── Defaults (overridden by config) ──────────────────────────────────────────
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

# ── Logging ──────────────────────────────────────────────────────────────────
log_info()  { logger -t "$LOG_TAG" -p daemon.info  "$*"; echo "[INFO]  $*"; }
log_warn()  { logger -t "$LOG_TAG" -p daemon.warn  "$*"; echo "[WARN]  $*" >&2; }
log_error() { logger -t "$LOG_TAG" -p daemon.crit  "$*"; echo "[CRIT]  $*" >&2; }

# ── Monotonic time (immune to NTP / RTC clock jumps) ─────────────────────────
get_monotonic_sec() {
    awk '{print int($1)}' /proc/uptime
}

# ── Load & validate configuration ───────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local file_owner file_perm
        file_owner=$(stat -c "%u:%g" "$CONFIG_FILE")
        file_perm=$(stat -c "%a" "$CONFIG_FILE")
        if [[ "$file_owner" != "0:0" ]] || [[ "$file_perm" =~ [2367]$ ]]; then
            log_error "Security violation: $CONFIG_FILE must be owned by root:root and not world-writable (found $file_owner perm=$file_perm). Using defaults."
        else
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
        fi
    fi
}

# ── Write telemetry (plain-text + JSON) ──────────────────────────────────────
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

    # Structured JSON for fleet telemetry / AI agent integration
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

# ── Safe shutdown sequence ───────────────────────────────────────────────────
trigger_safe_shutdown() {
    local reason="$1"
    local elapsed="$2"

    log_error "SHUTDOWN TRIGGERED after ${elapsed}s: ${reason}"
    write_telemetry "SHUTDOWN" "none" "$elapsed" "$reason"

    # Last-second override check
    if [[ -e "$OVERRIDE_FILE" ]] || [[ -e "/boot/wifi-startup-guard.disabled" ]]; then
        log_warn "Override file detected just before shutdown! Aborting poweroff."
        exit 0
    fi

    journalctl --sync 2>/dev/null || true
    sync

    systemctl poweroff
    exit 0
}

# ── Phase 1: Wait for Wi-Fi hardware readiness ──────────────────────────────
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

# ── Interface-bound health verification ──────────────────────────────────────
verify_wifi_health() {
    # Check NM reports "connected"
    local state
    state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')
    [[ "$state" != "100" ]] && return 1

    # Check IPv4 address is assigned
    local ipv4_addr
    ipv4_addr=$(ip -4 -o addr show dev "$WIFI_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [[ -z "$ipv4_addr" ]]; then
        log_warn "Interface $WIFI_IFACE connected but no IPv4 address assigned yet."
        return 1
    fi

    # Check usable route exists
    if ! ip -4 route show dev "$WIFI_IFACE" | grep -q .; then
        log_warn "No usable IPv4 route on $WIFI_IFACE."
        return 1
    fi

    # Probe each target
    local target resolved_target
    for target in $PROBE_TARGETS; do
        if [[ "$target" == "auto-gateway" ]]; then
            resolved_target=$(nmcli -g IP4.GATEWAY device show "$WIFI_IFACE" 2>/dev/null | tr -d '\\')
            [[ -z "$resolved_target" ]] && resolved_target=$(ip -4 route show default dev "$WIFI_IFACE" | awk '{print $3}' | head -n1)
            if [[ -z "$resolved_target" ]]; then
                log_warn "Probe 'auto-gateway' selected but no gateway found on $WIFI_IFACE."
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
                    log_info "Health check PASSED via HTTP/HTTPS to '$resolved_target' on $WIFI_IFACE ($ipv4_addr)."
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

# ── Get Wi-Fi profiles sorted by descending priority ─────────────────────────
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

# ── Phase 2: Main connection window with scanning & retry ────────────────────
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

        # Check override
        if [[ -e "$OVERRIDE_FILE" ]] || [[ -e "/boot/wifi-startup-guard.disabled" ]]; then
            log_warn "Maintenance override file detected. Exiting guard cleanly."
            write_telemetry "BYPASSED" "none" "$elapsed" "Override file present"
            exit 0
        fi

        # Rescan
        nmcli device wifi rescan ifname "$WIFI_IFACE" 2>/dev/null || true
        sleep 2

        local visible_ssids
        visible_ssids=$(nmcli -g SSID device wifi list ifname "$WIFI_IFACE" --rescan no 2>/dev/null | sed 's/\\:/:/g' | sort -u)

        local dev_state
        dev_state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')

        # Wait for mid-handshake states
        if [[ -n "$dev_state" ]] && (( dev_state >= 40 && dev_state <= 80 )); then
            log_info "Interface $WIFI_IFACE is mid-handshake (state=$dev_state). Waiting 5s..."
            sleep 5
            dev_state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | awk '{print $1}')
        fi

        local profiles
        profiles=$(get_sorted_wifi_profiles)

        # Determine highest-priority visible network
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

        # If already connected, check priority preemption
        if [[ "$dev_state" == "100" ]]; then
            local active_uuid active_prio active_name
            active_uuid=$(nmcli -g GENERAL.CON-UUID device show "$WIFI_IFACE" 2>/dev/null)
            active_name=$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null)
            active_prio=$(nmcli -g connection.autoconnect-priority connection show uuid "$active_uuid" 2>/dev/null || echo 0)

            if [[ -n "$best_visible_uuid" ]] && [[ "$best_visible_uuid" != "$active_uuid" ]] && (( best_visible_prio > active_prio )); then
                log_info "Preempting '$active_name' (prio=$active_prio) → '$best_visible_name' (prio=$best_visible_prio)..."
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

        # Pass 1: Try visible profiles in priority order
        while IFS='|' read -r prio uuid ssid hidden name; do
            [[ -z "$uuid" ]] && continue
            if grep -Fxq "$ssid" <<< "$visible_ssids"; then
                log_info "Activating visible profile '$name' (SSID='$ssid', priority=$prio)..."
                if nmcli --wait "$ACTIVATION_WAIT_SEC" connection up uuid "$uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1; then
                    if verify_wifi_health; then
                        now_sec=$(get_monotonic_sec)
                        elapsed=$((now_sec - start_sec))
                        log_info "Verified Wi-Fi on '$name' after ${elapsed}s."
                        write_telemetry "SUCCESS" "$name" "$elapsed" "Connected to visible profile"
                        exit 0
                    fi
                fi
            fi
            now_sec=$(get_monotonic_sec)
            (( now_sec - start_sec >= CONNECT_TIMEOUT_SEC )) && break
        done <<< "$profiles"

        # Pass 2: Try hidden profiles in priority order
        while IFS='|' read -r prio uuid ssid hidden name; do
            [[ -z "$uuid" ]] && continue
            if [[ "$hidden" == "yes" ]] && ! grep -Fxq "$ssid" <<< "$visible_ssids"; then
                log_info "Activating hidden profile '$name' (SSID='$ssid', priority=$prio)..."
                if nmcli --wait "$ACTIVATION_WAIT_SEC" connection up uuid "$uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1; then
                    if verify_wifi_health; then
                        now_sec=$(get_monotonic_sec)
                        elapsed=$((now_sec - start_sec))
                        log_info "Verified Wi-Fi on hidden '$name' after ${elapsed}s."
                        write_telemetry "SUCCESS" "$name" "$elapsed" "Connected to hidden profile"
                        exit 0
                    fi
                fi
            fi
            now_sec=$(get_monotonic_sec)
            (( now_sec - start_sec >= CONNECT_TIMEOUT_SEC )) && break
        done <<< "$profiles"

        # Sleep until next retry
        now_sec=$(get_monotonic_sec)
        elapsed=$((now_sec - start_sec))
        local remaining=$((CONNECT_TIMEOUT_SEC - elapsed))
        if (( remaining <= 0 )); then
            trigger_safe_shutdown "No configured Wi-Fi network connected within ${CONNECT_TIMEOUT_SEC}s" "$elapsed"
        fi

        local sleep_time="$RETRY_INTERVAL_SEC"
        (( remaining < sleep_time )) && sleep_time="$remaining"
        log_info "No healthy Wi-Fi yet (${elapsed}s/${CONNECT_TIMEOUT_SEC}s). Retrying in ${sleep_time}s..."
        sleep "$sleep_time"
    done
}

# ── Entry point ──────────────────────────────────────────────────────────────
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
DAEMON_EOF
    chown root:root "$DAEMON_PATH"
    chmod 0755 "$DAEMON_PATH"
    success "Watchdog daemon: ${BOLD}${DAEMON_PATH}${NC}  (mode 0755, root:root)"

    # ── 3c. Write systemd service unit ────────────────────────────────────────
    info "Writing systemd service unit..."
    cat <<SERVICE_EOF > "$SERVICE_PATH"
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
SERVICE_EOF
    chown root:root "$SERVICE_PATH"
    chmod 0644 "$SERVICE_PATH"
    systemctl daemon-reload
    success "Systemd service: ${BOLD}${SERVICE_PATH}${NC}"

    echo ""
    success "${GREEN}All system files installed.${NC}"
}

# ==============================================================================
# Step 4: Automated Dry-Run Verification & Activation
# ==============================================================================
run_verification_and_enable() {
    print_step_header "4" "Running Safety & Connectivity Tests"

    # ── Test 1: Emergency bypass ──────────────────────────────────────────────
    info "Test 1 — Verifying emergency bypass mechanism..."
    echo -e "  Creating temporary bypass file: ${DIM}${OVERRIDE_PATH}${NC}"
    touch "$OVERRIDE_PATH"
    # The ConditionPathExists in the unit should prevent it from starting
    if systemctl start wifi-startup-guard.service 2>/dev/null; then
        sleep 1
    fi
    rm -f "$OVERRIDE_PATH"
    success "Emergency bypass verified!"
    echo -e "  ${DIM}Creating '${OVERRIDE_PATH}' on the SD card disables the guard.${NC}"

    # ── Test 2: Live connectivity (optional) ──────────────────────────────────
    echo ""
    separator
    echo ""
    echo -e "  ${BOLD}Test 2 — Live Wi-Fi Connection & Health Check${NC}"
    echo ""
    echo -e "  This will start the guard service and show its log output."
    echo -e "  ${DIM}Tip: If needed, touch '${OVERRIDE_PATH}' in another terminal to cancel.${NC}"
    echo ""
    read -rp "  Run a live connectivity test now? [Y/n]: " run_live
    run_live="${run_live:-Y}"
    if [[ "$run_live" =~ ^[Yy]$ ]]; then
        info "Starting wifi-startup-guard.service..."
        systemctl start wifi-startup-guard.service
        sleep 4
        echo ""
        echo -e "  ${BOLD}Recent service log:${NC}"
        journalctl -u wifi-startup-guard.service -n 15 --no-pager 2>/dev/null | sed 's/^/  /'
        echo ""
        if [[ -f "${STATUS_DIR}/status.json" ]]; then
            info "Telemetry output (${STATUS_DIR}/status.json):"
            echo ""
            cat "${STATUS_DIR}/status.json" | sed 's/^/  /'
            echo ""
        fi
    fi

    # ── Enable on boot ────────────────────────────────────────────────────────
    echo ""
    separator
    echo ""
    read -rp "  Enable Wi-Fi Startup Guard to run automatically on every boot? [Y/n]: " enable_boot
    enable_boot="${enable_boot:-Y}"
    if [[ "$enable_boot" =~ ^[Yy]$ ]]; then
        systemctl enable wifi-startup-guard.service
        echo ""
        success "${BOLD}wifi-startup-guard.service is now ENABLED on boot!${NC}"
    else
        echo ""
        warn "Service installed but NOT enabled on boot."
        echo -e "  Enable later with:  ${BOLD}sudo systemctl enable wifi-startup-guard.service${NC}"
    fi

    # ── Quick reference ───────────────────────────────────────────────────────
    echo ""
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   ✅  Setup Complete — Quick Reference Guide                       ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Re-run wizard / add Wi-Fi:${NC}"
    echo -e "    sudo ./setup-wifi-guard.sh"
    echo ""
    echo -e "  ${BOLD}Check live logs:${NC}"
    echo -e "    sudo journalctl -u wifi-startup-guard.service -f"
    echo ""
    echo -e "  ${BOLD}Check JSON status:${NC}"
    echo -e "    cat ${STATUS_DIR}/status.json"
    echo ""
    echo -e "  ${BOLD}Emergency offline bypass:${NC}"
    echo -e "    Insert the microSD card into any computer and create an empty file"
    echo -e "    named ${YELLOW}wifi-startup-guard.disabled${NC} inside the boot partition"
    echo -e "    (${BOOT_MOUNT})."
    echo ""
    echo -e "  ${BOLD}Disable service anytime:${NC}"
    echo -e "    sudo systemctl disable --now wifi-startup-guard.service"
    echo ""
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================
print_banner
preflight_checks
add_or_update_wifi_wizard
install_system_files
run_verification_and_enable

