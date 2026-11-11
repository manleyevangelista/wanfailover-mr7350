#!/bin/bash
# WAN Failover for Linksys MR7350
# Primary: wan, Secondary: lan4
# Uses ICMP ping for health checks
# Location:  /etc/wanfailover_monitor.sh
# Version 1 by Manley Evangelista. Based on kekneus373's mwan-diy script. 

PRIORITY_WAN="wan"							# Preferred gateway
BACKUP_WAN="lan4"							# Fallback
INTERFACE_NAME_PRIMARY="wan"						# Logical name in /etc/config/network
INTERFACE_NAME_BACKUP="lan4"     					# Logical name in /etc/config/network
PING_TARGETS="8.8.8.8 1.1.1.1 208.67.222.222"				# Google, Cloudflare, Cisco
RETRIES_PER_TARGET=1							# Maximum ping retry count
CONSECUTIVE_FAILURES_REQUIRED=1						# Failed cycles count to trigger fallback
CHECK_INTERVAL=30							# Between full cycles
COOLDOWN_AFTER_FAILOVER=30						# Prevent flapping
INITIAL_DELAY=10							# Let DHCP settle at boot
LOG_FILE="/var/log/wanfailover-mr7350.log"				# Current logfile
MAX_LOG_SIZE_KB=1500							# Rotate when exceeding this size

# RGB status LED: turquoise = WAN, green = LAN4, red = no confirmed connection
set_status_led() {
    local color="$1"
    local led_dir="/sys/class/leds"
    local channel

    for channel in red green blue; do
        [ -e "$led_dir/$channel:status/trigger" ] || return 0
    done

    for channel in red green blue; do
        echo none > "$led_dir/$channel:status/trigger"
        echo 0 > "$led_dir/$channel:status/brightness"
    done

    case "$color" in
        turquoise)
            echo 255 > "$led_dir/green:status/brightness"
            echo 255 > "$led_dir/blue:status/brightness"
            ;;
        green)
            echo 255 > "$led_dir/green:status/brightness"
            ;;
        red)
            echo 255 > "$led_dir/red:status/brightness"
            ;;
    esac
}

# Logging function
log_msg() {
    # Rotate log if too large before appending
    rotate_log_if_needed
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

rotate_log_if_needed() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi

    local file_size_kb
    file_size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1)

    if [ "${file_size_kb:-0}" -gt "$MAX_LOG_SIZE_KB" ]; then
        # Shift backups
        [ -f "${LOG_FILE}.2" ] && mv "${LOG_FILE}.2" "${LOG_FILE}.3"
        [ -f "${LOG_FILE}.1" ] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"

        # Current becomes .1
        cp "$LOG_FILE" "${LOG_FILE}.1"
        : > "$LOG_FILE"
		# dd if=/dev/null of="$LOG_FILE" bs=1 count=0

        echo "$(date '+%Y-%m-%d %H:%M:%S') - Log rotated (exceeded ${MAX_LOG_SIZE_KB}KB)"
    fi
}

# Check if interface has actual connectivity (not just link up)
check_connectivity() {
    local iface="$1"

    # Track duration for diagnostic logging
    local check_start
    check_start=$(date +%s)

    log_msg "Checking connectivity on $iface..."

    # Method 1: Physical & Software link check
    ensure_enabled
    if ! ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
	log_msg "✗ LINK DOWN: Interface $iface is physically not UP"
        return 1
    fi

    # Level 2: Is UCI disabled flag set?
    local uci_disabled
    uci_disabled=$(uci get network."$INTERFACE_NAME_PRIMARY".disabled 2>/dev/null)

    if [ "$uci_disabled" = "1" ]; then
        echo "✗ SOFT OFF: Interface $iface is disabled in UCI - fixing now..."
	ensure_enabled
        return 1
    fi

    # Method 2: Has IP address assigned?
    if ! ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
	log_msg "✗ NO IP: Interface $iface has no IPv4 address"
        return 1
    fi

    # Method 3: Try ping with multiple targets
    for target in $PING_TARGETS; do
        if ping -c "$RETRIES_PER_TARGET" -W 5 -I "$iface" "$target" > /dev/null 2>&1; then
            local check_end
            check_end=$(date +%s)
            local duration=$((check_end - check_start))
            log_msg "✓ PASS: $iface reachable via $target (${duration}s)"
            return 0
        fi

        log_msg "✗ FAIL: Could not reach $target via $iface"
    done

    log_msg "✗ CRITICAL: Connectivity FAILED on $iface after testing all targets"
    return 1
}

# Enable WAN interface
enable_wan() {
    local iface_name="$1"
    log_msg "Enabling WAN interface: $iface_name"

    uci set network."$iface_name".disabled='0'
    uci commit network
    ifup "$iface_name" 2>/dev/null || true
    sleep 3
}

# Get currently active WAN interface (which default route is being used)
get_active_gateway_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    echo "${iface:-none}"
}

# Bounce one OpenWrt logical interface on a route-change event.
# Interfaces are cycled sequentially, never intentionally down together.
cycle_wan_interface() {
    local iface_name="$1"
    local attempt

    log_msg "EVENT: Cycling $iface_name (ifdown/ifup)"
    if ! ifdown "$iface_name"; then
        log_msg "WARNING: ifdown failed for $iface_name"
    fi
    if ! ifup "$iface_name"; then
        log_msg "ERROR: ifup failed for $iface_name"
        return 1
    fi

    # ifup starts DHCP asynchronously. Wait until the interface has IPv4.
    for ((attempt=0; attempt<15; attempt++)); do
        if ip -4 addr show "$iface_name" 2>/dev/null | grep -q 'inet '; then
            log_msg "EVENT: $iface_name has IPv4 after cycle"
            return 0
        fi
        sleep 1
    done
    log_msg "WARNING: $iface_name has no IPv4 after cycling"
    return 1
}

# Force failover from current primary to backup
failover_to_backup() {
    log_msg "=== FAILOVER INITIATED ==="
    log_msg "Primary ($PRIORITY_WAN) unreachable, switching to backup ($BACKUP_WAN)"
    local newroute
    local newsrc_full
    local newsrc_ip

    newroute=$(ifstatus "$INTERFACE_NAME_BACKUP" | jq -r '.route[0].nexthop')
    newsrc_full=$(ifstatus "$INTERFACE_NAME_BACKUP" | jq -r '.route[0].source')
    newsrc_ip=$(echo "$newsrc_full" | cut -d'/' -f1) # Strip the /32 mask

    ensure_enabled
    if [ -n "$newroute" ] && [ -n "$newsrc_ip" ]; then
        log_msg "→ Set eth2 the primary route"
    	log_msg "ip route replace default via $newroute dev $BACKUP_WAN src $newsrc_ip"
    	ip route replace default via $newroute dev $BACKUP_WAN src $newsrc_ip
    else
	log_msg "✗ Failed to parse route data for $BACKUP_WAN"
	return 1
    fi

    # Refresh DNS and routes
    service firewall restart
    sleep 5
    log_msg "✓ Failover complete - Backup WAN now primary path"
    set_status_led green
    # WAN is never cycled. Keep the backup route selected.
    ip route replace default via "$newroute" dev "$BACKUP_WAN" src "$newsrc_ip"
    return 0
}

# Restore primary when it recovers
restore_primary() {
    local routebak
    routebak=$(ip route | grep default)
    log_msg "=== RESTORE VALIDATION PHASE ==="
    ensure_enabled

    # WAN was already verified by the monitor; do not bounce a healthy WAN
    # immediately before attempting to restore it.

    # STEP 1: Test connectivity WITH primary enabled
    if check_connectivity "$PRIORITY_WAN"; then
        local newroute
	local newsrc_full
	local newsrc_ip

	log_msg "✓ Primary ($PRIORITY_WAN) connectivity VERIFIED - proceeding with restore"
	newroute=$(ifstatus "$INTERFACE_NAME_PRIMARY" | jq -r '.route[0].nexthop')
	newsrc_full=$(ifstatus "$INTERFACE_NAME_PRIMARY" | jq -r '.route[0].source')
	newsrc_ip=$(echo "$newsrc_full" | cut -d'/' -f1) # Strip the /32 mask

        # Rebuild routing table only AFTER confirming primary works
	if [ -n "$newroute" ] && [ -n "$newsrc_ip" ]; then
            log_msg "→ Set eth1 the primary route"
  	    log_msg "ip route replace default via $newroute dev $PRIORITY_WAN src $newsrc_ip"
  	    ip route replace default via $newroute dev $PRIORITY_WAN src $newsrc_ip
	else
	    echo "✗ Failed to parse route data for $PRIORITY_WAN"
	    return 1
	fi
        service firewall restart
        sleep 5

        log_msg "✓ Restore complete - Back to Primary WAN"
        set_status_led turquoise
        ip route replace default via "$newroute" dev "$PRIORITY_WAN" src "$newsrc_ip"
        return 0
    else
        # Primary failed test - rollback immediately
        log_msg "✗ Primary FAILED connectivity test"
        ensure_enabled
	if ip route | grep default | grep -q eth1; then
	    log_msg "→ Route changed by OpenWRT; rolling back"
	    ip route replace "$routebak"
	fi
        service firewall restart
	sleep 5
        return 1
    fi
}

ensure_enabled() {
    local disabled_status
    disabled_status=$(uci get network."$INTERFACE_NAME_BACKUP".disabled 2>/dev/null)

    if [ "$disabled_status" != "0" ] || [ -z "$disabled_status" ]; then
        log_msg "→ Backup soft disabled (${disabled_status}), enabling now..."
        enable_wan "$INTERFACE_NAME_BACKUP"
    else
        log_msg "✓ Backup interface already enabled"
    fi

    disabled_status=$(uci get network."$INTERFACE_NAME_PRIMARY".disabled 2>/dev/null)

    if [ "$disabled_status" != "0" ] || [ -z "$disabled_status" ]; then
        log_msg "→ Primary soft disabled (${disabled_status}), enabling now..."
        enable_wan "$INTERFACE_NAME_PRIMARY"
    else
        log_msg "✓ Primary interface already enabled"
    fi

}

check_current_state() {
    local current_iface
    current_iface=$(get_active_gateway_iface)

    if [ "$current_iface" = "$PRIORITY_WAN" ]; then
        printf 'PRIMARY_ACTIVE\n'
    elif [ "$current_iface" = "$BACKUP_WAN" ]; then
        printf 'BACKUP_ACTIVE\n'
    else
        printf 'UNKNOWN\n'
    fi
}

monitor_loop() {
    local consecutive_fails=0
    local last_action_time=0
    local cycle_count=0

    log_msg "=== WAN Failover Monitor Starting ==="
    log_msg "Priority: ${PRIORITY_WAN}, Backup: ${BACKUP_WAN}"

    set_status_led red
    sleep "$INITIAL_DELAY"

    while true; do
        ((cycle_count++))
        local cycle_start_time=$(date +%s)

        # Calculate cooldown remaining from last action
        local elapsed_since_action=$(( $(date +%s) - last_action_time ))
        local cooldown_remaining=$((COOLDOWN_AFTER_FAILOVER - elapsed_since_action))

        # Respect failover cooldown period
        if [ "$cooldown_remaining" -gt 0 ]; then
            log_msg "--- Cycle $cycle_count ---"
            log_msg "Cooldown active (${cooldown_remaining}s remaining)"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        local current_route_state=$(check_current_state)
        local current_iface=$(get_active_gateway_iface)
        log_msg "→ Current route state: $current_route_state via $current_iface"

	# Version 4 logic
        if check_connectivity "$PRIORITY_WAN"; then
            consecutive_fails=0
            if [ "$current_route_state" = "PRIMARY_ACTIVE" ]; then
                set_status_led turquoise
            fi

            # Primary healthy - if on backup, restore priority
            if [ "$current_route_state" = "BACKUP_ACTIVE" ] && [ "$elapsed_since_action" -gt 60 ]; then
                log_msg "Primary recovered while backup active - initiating RESTORE"
                restore_primary
                last_action_time=$(date +%s)
            fi
        else
            ((consecutive_fails++))
            log_msg "Primary failure count: $consecutive_fails/$CONSECUTIVE_FAILURES_REQUIRED"

            if [ "$consecutive_fails" -ge "$CONSECUTIVE_FAILURES_REQUIRED" ]; then
                log_msg "CONFIRMED: Primary ($PRIORITY_WAN) DOWN after $consecutive_fails failures"

                # Select LAN4 first; only reset it if it has no internet.
                # Do not cycle the primary WAN.
                ensure_enabled
                if [ "$current_route_state" != "BACKUP_ACTIVE" ]; then
                    failover_to_backup || log_msg "WARNING: LAN4 route not ready yet"
                fi

                while ! check_connectivity "$BACKUP_WAN"; do
                    log_msg "LAN4 offline after failover - cycling LAN4"
                    set_status_led red
                    cycle_wan_interface "$INTERFACE_NAME_BACKUP" || true

                    # ifdown/ifup can remove or replace the default route;
                    # select LAN4 again after each cycle.
                    if [ "$(check_current_state)" != "BACKUP_ACTIVE" ]; then
                        failover_to_backup || log_msg "WARNING: LAN4 route still unavailable"
                    fi

                    # A recovered primary takes precedence; don't keep
                    # resetting LAN4 after WAN has returned.
                    if check_connectivity "$PRIORITY_WAN"; then
                        log_msg "WAN recovered during LAN4 recovery"
                        if [ "$(check_current_state)" = "BACKUP_ACTIVE" ]; then
                            restore_primary
                        fi
                        break
                    fi
                done

                if check_connectivity "$BACKUP_WAN" &&
                   ! check_connectivity "$PRIORITY_WAN"; then
                    if [ "$(check_current_state)" != "BACKUP_ACTIVE" ]; then
                        failover_to_backup
                    fi
                    log_msg "LAN4 internet secured"
                    set_status_led green
                    last_action_time=$(date +%s)
                fi
                consecutive_fails=0
            fi
        fi

        local cycle_end_time=$(date +%s)
        local cycle_duration=$((cycle_end_time - cycle_start_time))
        local sleep_remaining=$((CHECK_INTERVAL - cycle_duration))

        if [ "$sleep_remaining" -gt 0 ]; then
            sleep "$sleep_remaining"
        else
            log_msg "⚠ WARNING: Cycle exceeded interval (${cycle_duration}s)"
            sleep 5
        fi
    done
}

# Signal handlers for graceful shutdown
cleanup() {
    log_msg "=== Monitor Shutting Down ==="
    # Also log to syslog for persistent records
    logger -t "wanfailover-mr7350" "Monitor shutting down gracefully"
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP EXIT

# Validate prerequisites
validate_setup() {
    # Check UCI config exists
    if ! uci get network."$INTERFACE_NAME_PRIMARY" &>/dev/null; then
        log_msg "✗ ERROR: Primary interface '$INTERFACE_NAME_PRIMARY' not found in UCI"
        log_msg "→ Check /etc/config/network for correct interface names"
        exit 1
    fi

    log_msg "Configuration validated, starting monitor (Ctrl+C to stop)..."
}

# Main execution
if [ "$EUID" -ne 0 ]; then
    echo "✗ Error: This script requires root privileges" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

validate_setup
monitor_loop
