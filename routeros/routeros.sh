#!/system/bin/sh
set -u

VM_DIR=/data/local/mikrotik
BUNDLED_CROSVM="$VM_DIR/crosvm"
CROSVM=""
CROSVM_STYLE=""
CROSVM_NET_STYLE=""
DISK="$VM_DIR/routeros.img"
CONFIG="$VM_DIR/vm.conf"
PIDFILE="$VM_DIR/crosvm.pid"
MONITOR_PIDFILE="$VM_DIR/network-monitor.pid"
WATCHDOG_PIDFILE="$VM_DIR/vm-watchdog.pid"
ACTIVE_MODE_FILE="$VM_DIR/active-tether-mode"
MONITOR_POLL_SECONDS=3
MONITOR_FULL_SYNC_CYCLES=20
DIRECT_BR0_MONITOR_POLL_SECONDS=10
DIRECT_BR0_FULL_SYNC_CYCLES=30
RA6="$VM_DIR/ra6"
KVM_PROBE="$VM_DIR/kvm-probe"
DHCP_RELAY="$VM_DIR/dhcp-relay"
IPV6_PREFIX_FILE="$VM_DIR/ipv6-prefix"
TAKEOVER_FLAG="$VM_DIR/takeover.enabled"
SOCKET="$VM_DIR/crosvm.sock"
LOG="$VM_DIR/crosvm.log"
CONSOLE="$VM_DIR/console.log"
WAN_TAP=ros-wan
LAN_TAP=ros-lan
DEFAULT_LAN_BRIDGE=ros-br
NATIVE_TETHER_BRIDGE=br0
LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
WAN_HOST_IP=192.168.66.1
WAN_SUBNET=192.168.66.0/24
WAN_GUEST_IP=192.168.66.2
LAN_HOST_IP=192.168.88.2
LAN_SUBNET=192.168.88.0/24
LAN_GUEST_IP=192.168.88.1
LAN_NETMASK=255.255.255.0
# Android's iproute2 has no rt_tables file, so custom tables must be numeric.
# 1000 is unused by the framework (it uses 97-99 and 100+ per-network tables).
ROS_TABLE=1000
RULE_PRIO=100
ROUTED_TETHER_RULE_PRIO=1053
UPSTREAM_RULE_PRIO=1050
IPV6_OUT_RULE_PRIO=1051
IPV6_IN_RULE_PRIO=1052
IPV6_BLOCK_PRIO=100
IPV6_FORWARD_CHAIN=ROS6_VM
# Android's policy routing ends with "from all unreachable"; without an
# explicit rule, packets from the Android host itself to the RouterOS subnets
# are dropped before reaching the taps. Point them at the main table.
HOST_ROUTE_PRIO=1049
SSH_DNAT_PORT=2223
WEB_DNAT_PORT=8080
ROUTED_IFACES_FILE="$VM_DIR/routed-tethers"
PROXYARP_IFACES_FILE="$VM_DIR/proxyarp-tethers"
DIRECT_BR0_ADDR_FILE="$VM_DIR/direct-br0.addr"
STOP_TRANSITION_DNS_FILE="$VM_DIR/stopped-transition-dns"
GARP="$VM_DIR/garp"
EFFECTIVE_TETHER_MODE=""
EFFECTIVE_CPU_AFFINITY=""
EFFECTIVE_CPU_CAPACITY=""
EFFECTIVE_CPU_CLUSTERS=""
EFFECTIVE_NET_QUEUES=1
UNSAFE_NATIVE_BRIDGE=0
TETHER_STATE=""
TETHER_STATE_SET=0

die() {
    echo "routeros: $*" >&2
    exit 1
}

load_config() {
    [ -r "$CONFIG" ] || die "missing $CONFIG; run deploy-routeros.sh first"
    . "$CONFIG"
    : "${ROOT_DEVICE:=/dev/vda}"
    : "${VM_CPUS:=4}"
    : "${VM_CPU_AFFINITY:=auto}"
    : "${VM_NET_QUEUES:=auto}"
    : "${VM_MEMORY_MIB:=384}"
    : "${AUTO_TAKEOVER:=0}"
    : "${NETWORK_MONITOR:=1}"
    : "${IPV6_PASSTHROUGH:=1}"
    : "${CROSVM_PATH:=auto}"
    : "${CROSVM_EXTRA_ARGS:=}"
    : "${CELLULAR_IFACE:=auto}"
    : "${CELLULAR_ROUTE_TABLE:=auto}"
    : "${TETHER_IFACE_PATTERNS:=auto}"
    : "${TETHER_MODE:=directbr0}"
    : "${LAN_HOST_IP:=192.168.88.2}"
    : "${LAN_GUEST_IP:=192.168.88.1}"
    : "${LAN_NETMASK:=255.255.255.0}"
    : "${STANDALONE:=0}"
    # The UFI plug-in currently supports the platform's normal /24 LAN only.
    # Derive the subnet after vm.conf has overridden the built-in defaults.
    LAN_SUBNET="$(printf '%s\n' "$LAN_GUEST_IP" | awk -F. 'NF == 4 { print $1 "." $2 "." $3 ".0/24" }')"
    [ -n "$LAN_SUBNET" ] || die "invalid LAN_GUEST_IP: $LAN_GUEST_IP"
    case "$IPV6_PASSTHROUGH" in
        0|1) ;;
        *) die "IPV6_PASSTHROUGH must be 0 or 1" ;;
    esac
    case "$TETHER_MODE" in
        auto|bridge|routed|proxyarp|directbr0) ;;
        *) die "TETHER_MODE must be auto, bridge, routed, proxyarp, or directbr0" ;;
    esac
    case "$NETWORK_MONITOR" in
        0|1) ;;
        *) die "NETWORK_MONITOR must be 0 or 1" ;;
    esac
    case "$STANDALONE" in
        0|1) ;;
        *) die "STANDALONE must be 0 or 1" ;;
    esac
}

resolve_tether_mode() {
    LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
    platform="$(getprop ro.board.platform 2>/dev/null | tr 'A-Z' 'a-z')"
    soc="$(getprop ro.soc.model 2>/dev/null | tr 'A-Z' 'a-z')"
    product="$(getprop ro.product.device 2>/dev/null | tr 'A-Z' 'a-z')"
    model="$(getprop ro.product.model 2>/dev/null | tr 'A-Z' 'a-z')"
    UNSAFE_NATIVE_BRIDGE=0
    if { [ "$platform" = ums9620 ] || [ "$soc" = t760 ]; } && \
            { [ "$product" = mu300 ] || [ "$model" = f50 ]; } && \
            [ -d /sys/module/sprd_wlan_combo ]; then
        UNSAFE_NATIVE_BRIDGE=1
    fi
    case "$TETHER_MODE" in
        bridge|routed|proxyarp|directbr0) EFFECTIVE_TETHER_MODE="$TETHER_MODE" ;;
        auto)
            # UMS9620's Android 13 sprd_wlan_combo driver corrupts an skb when
            # its native hotspot bridge is extended with another Linux bridge.
            if [ "$UNSAFE_NATIVE_BRIDGE" = 1 ]; then
                EFFECTIVE_TETHER_MODE=proxyarp
            else
                EFFECTIVE_TETHER_MODE=bridge
            fi
            ;;
    esac
    # Standalone device mode: the VM keeps its own LAN bridge and IP but
    # never attaches tether clients, so always use the safe bridge path.
    if [ "${STANDALONE:-0}" = 1 ]; then
        EFFECTIVE_TETHER_MODE=bridge
        LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
    fi
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] && LAN_BRIDGE="$NATIVE_TETHER_BRIDGE"
}

use_active_tether_mode() {
    [ "${STANDALONE:-0}" = 1 ] && return 0
    [ -r "$ACTIVE_MODE_FILE" ] || return 0
    active_mode="$(cat "$ACTIVE_MODE_FILE" 2>/dev/null)"
    case "$active_mode" in
        bridge|routed|proxyarp|directbr0) EFFECTIVE_TETHER_MODE="$active_mode" ;;
        *) return 0 ;;
    esac
    LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] && LAN_BRIDGE="$NATIVE_TETHER_BRIDGE"
}

detect_cellular_iface() {
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        case "$iface" in
            sipa_eth*|rmnet_data*|rmnet*|ccmni*|seth*|pdp*)
                if ip -6 -o addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
                    echo "$iface"
                    return 0
                fi
                ;;
        esac
    done
    for iface in sipa_eth0 rmnet_data0 ccmni0 seth_lte0; do
        [ -e "/sys/class/net/$iface" ] && { echo "$iface"; return 0; }
    done
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        case "$iface" in
            sipa_eth*|rmnet_data*|ccmni*|seth*|pdp*) echo "$iface"; return 0 ;;
        esac
    done
    return 1
}

resolve_cpu_affinity() {
    EFFECTIVE_CPU_AFFINITY=""
    EFFECTIVE_CPU_CAPACITY=""
    EFFECTIVE_CPU_CLUSTERS=""
    case "$VM_CPU_AFFINITY" in
        none) return 0 ;;
        auto)
            selected_cpus="$(
                for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
                    cpu_id="${cpu_path##*cpu}"
                    if [ -r "$cpu_path/online" ] && [ "$(cat "$cpu_path/online" 2>/dev/null)" != 1 ]; then
                        continue
                    fi
                    cpu_score="$(cat "$cpu_path/cpu_capacity" 2>/dev/null)"
                    [ -n "$cpu_score" ] || cpu_score="$(cat "$cpu_path/cpufreq/cpuinfo_max_freq" 2>/dev/null)"
                    case "$cpu_score" in *[!0-9]*|'') cpu_score=0 ;; esac
                    echo "$cpu_score $cpu_id"
                done | sort -k1,1nr -k2,2n | head -n "$VM_CPUS"
            )"
            selected_count="$(printf '%s\n' "$selected_cpus" | sed '/^$/d' | wc -l | tr -d ' ')"
            [ "$selected_count" = "$VM_CPUS" ] || \
                die "VM_CPUS=$VM_CPUS exceeds the number of online Android CPUs ($selected_count)"
            EFFECTIVE_CPU_AFFINITY="$(printf '%s\n' "$selected_cpus" | awk '
                { if (NR > 1) printf ":"; printf "%d=%s", NR - 1, $2 }
                END { print "" }
            ')"
            # Tell the guest scheduler that a vCPU pinned to a little core is
            # not equivalent to one pinned to a big core. Normalize either
            # cpu_capacity or the cpufreq fallback to crosvm's 1024 scale.
            EFFECTIVE_CPU_CAPACITY="$(printf '%s\n' "$selected_cpus" | awk '
                NR == 1 { max = $1 }
                {
                    capacity = max > 0 ? int(($1 * 1024 + max / 2) / max) : 1024
                    if (capacity < 1) capacity = 1
                    if (NR > 1) printf ","
                    printf "%d=%d", NR - 1, capacity
                }
                END { print "" }
            ')"
            # selected_cpus is capacity-sorted, so equal-capacity vCPUs are
            # contiguous and can be represented as crosvm CPU clusters.
            EFFECTIVE_CPU_CLUSTERS="$(printf '%s\n' "$selected_cpus" | awk '
                function emit(first, last) {
                    if (output != "") output = output " "
                    output = output (first == last ? first : first "-" last)
                }
                NR == 1 { previous = $1; first = 0; next }
                $1 != previous { emit(first, NR - 2); first = NR - 1; previous = $1 }
                END { if (NR > 0) emit(first, NR - 1); print output }
            ')"
            ;;
        *[!0-9,:=-]*|'') die "invalid VM_CPU_AFFINITY: $VM_CPU_AFFINITY" ;;
        *) EFFECTIVE_CPU_AFFINITY="$VM_CPU_AFFINITY" ;;
    esac
}

resolve_net_queues() {
    case "$VM_NET_QUEUES" in
        auto)
            if echo "$crosvm_help" | grep -q -- '--net-vq-pairs'; then
                EFFECTIVE_NET_QUEUES="$VM_CPUS"
            else
                EFFECTIVE_NET_QUEUES=1
            fi
            ;;
        *[!0-9]*|'') die "VM_NET_QUEUES must be auto or a positive integer" ;;
        0) die "VM_NET_QUEUES must be positive" ;;
        *)
            [ "$VM_NET_QUEUES" -le "$VM_CPUS" ] || \
                die "VM_NET_QUEUES cannot exceed VM_CPUS"
            EFFECTIVE_NET_QUEUES="$VM_NET_QUEUES"
            if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ] && \
                    ! echo "$crosvm_help" | grep -q -- '--net-vq-pairs'; then
                die "selected crosvm does not support --net-vq-pairs"
            fi
            ;;
    esac
}

resolve_crosvm_path() {
    CROSVM=""
    case "$CROSVM_PATH" in
        auto)
            for candidate in \
                    /apex/com.android.virt/bin/crosvm \
                    /system/bin/crosvm /system_ext/bin/crosvm /vendor/bin/crosvm; do
                if [ -x "$candidate" ]; then
                    CROSVM="$candidate"
                    break
                fi
            done
            [ -n "$CROSVM" ] || CROSVM="$BUNDLED_CROSVM"
            ;;
        bundled) CROSVM="$BUNDLED_CROSVM" ;;
        /*) CROSVM="$CROSVM_PATH" ;;
        *) die "CROSVM_PATH must be auto, bundled, or an absolute device path" ;;
    esac
    [ -x "$CROSVM" ] || die "crosvm is not executable: $CROSVM"
}

resolve_device_config() {
    resolve_crosvm_path

    crosvm_help="$("$CROSVM" run --help 2>&1)"
    if echo "$crosvm_help" | grep -q -- '--block[ =]'; then
        CROSVM_STYLE=block
    elif echo "$crosvm_help" | grep -q -- '--rwdisk'; then
        CROSVM_STYLE=rwdisk
    else
        die "unsupported crosvm command line: neither --block nor --rwdisk is available"
    fi
    if echo "$crosvm_help" | grep -q -- 'tap-name=STRING' \
        && echo "$crosvm_help" | grep -q -- 'vq-pairs=N'; then
        CROSVM_NET_STYLE="modern"
    else
        CROSVM_NET_STYLE="legacy"
    fi
    resolve_cpu_affinity
    resolve_net_queues
    if [ -n "$EFFECTIVE_CPU_AFFINITY" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-affinity'; then
        die "selected crosvm does not support --cpu-affinity"
    fi
    if [ -n "$EFFECTIVE_CPU_CAPACITY" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-capacity'; then
        die "selected crosvm does not support --cpu-capacity"
    fi
    if [ -n "$EFFECTIVE_CPU_CLUSTERS" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-cluster'; then
        die "selected crosvm does not support --cpu-cluster"
    fi

    if [ "$CELLULAR_IFACE" = auto ]; then
        CELLULAR_IFACE="$(detect_cellular_iface)" || \
            die "cannot detect cellular interface; set CELLULAR_IFACE in config.env"
    fi
    [ -e "/sys/class/net/$CELLULAR_IFACE" ] || \
        die "cellular interface does not exist: $CELLULAR_IFACE"
    [ "$CELLULAR_ROUTE_TABLE" = auto ] && CELLULAR_ROUTE_TABLE="$CELLULAR_IFACE"
    resolve_tether_mode
}

matches_tether_pattern() {
    iface="$1"
    [ "$TETHER_IFACE_PATTERNS" = auto ] && return 0
    for pattern in $TETHER_IFACE_PATTERNS; do
        case "$iface" in $pattern) return 0 ;; esac
    done
    return 1
}

is_tether_candidate() {
    iface="$1"
    case "$iface" in
        lo|dummy*|tun*|ip6tnl*|sit*|gre*|gretap*|erspan*|vowifi*|ros-*|rosx-*) return 1 ;;
    esac
    [ "$iface" = "$CELLULAR_IFACE" ] && return 1
    matches_tether_pattern "$iface" && is_tethered "$iface"
}

# Potential downstreams must be protected before Android reports TetheredState.
# Otherwise IpServer can leak its first .0.x/42.x DHCP offer during USB gadget
# recreation, before the network monitor has attached the interface to RouterOS.
is_tether_capable() {
    iface="$1"
    if [ "$TETHER_IFACE_PATTERNS" != auto ]; then
        matches_tether_pattern "$iface"
        return
    fi
    case "$iface" in
        sipa_usb*|rndis*|wlan*|softap*|ap_br_wlan*|ap_br_softap*|bt-pan) return 0 ;;
    esac
    return 1
}

is_running() {
    [ -r "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CROSVM"
}

ensure_jump() {
    table="$1"
    parent="$2"
    child="$3"
    if ! iptables -t "$table" -C "$parent" -j "$child" 2>/dev/null; then
        iptables -t "$table" -I "$parent" 1 -j "$child"
    fi
}

delete_jump_and_chain() {
    table="$1"
    parent="$2"
    child="$3"
    while iptables -t "$table" -C "$parent" -j "$child" 2>/dev/null; do
        iptables -t "$table" -D "$parent" -j "$child" || break
    done
    iptables -t "$table" -F "$child" 2>/dev/null || true
    iptables -t "$table" -X "$child" 2>/dev/null || true
}

delete_ip6_jump_and_chain() {
    parent="$1"
    child="$2"
    while ip6tables -C "$parent" -j "$child" 2>/dev/null; do
        ip6tables -D "$parent" -j "$child" || break
    done
    ip6tables -F "$child" 2>/dev/null || true
    ip6tables -X "$child" 2>/dev/null || true
}

ensure_ip6_jump() {
    parent="$1"
    child="$2"
    if ! ip6tables -C "$parent" -j "$child" 2>/dev/null; then
        ip6tables -I "$parent" 1 -j "$child"
    fi
}

is_tethered() {
    iface="$1"
    if [ "$TETHER_STATE_SET" = 1 ]; then
        case "$TETHER_STATE" in
            *"$iface - TetheredState"*) return 0 ;;
        esac
        return 1
    fi
    dumpsys tethering 2>/dev/null | grep -q "^[[:space:]]*$iface - TetheredState"
}

bridge_attach() {
    iface="$1"
    [ -e "/sys/class/net/$iface" ] || return 0
    if [ -d "/sys/class/net/$iface/bridge" ]; then
        tag="$(printf '%s' "$iface" | tr -cd 'A-Za-z0-9' | cut -c1-7)"
        connector_host="rosx-${tag}h"
        connector_peer="rosx-${tag}p"
        if [ ! -e "/sys/class/net/$connector_host" ]; then
            ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' > "$VM_DIR/bridge-$iface.addr"
            ip link add "$connector_host" type veth peer name "$connector_peer"
            ip link set dev "$connector_host" master "$LAN_BRIDGE"
            ip link set dev "$connector_peer" master "$iface"
            ip link set dev "$connector_host" up
            ip link set dev "$connector_peer" up
            touch "$VM_DIR/bridge-$iface.connector"
        fi
        ip -4 addr flush dev "$iface" 2>/dev/null || true
        ip link set dev "$iface" up
        return 0
    fi
    current_master="$(basename "$(readlink "/sys/class/net/$iface/master" 2>/dev/null)" 2>/dev/null)"
    if [ "$current_master" != "$LAN_BRIDGE" ]; then
        ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' > "$VM_DIR/bridge-$iface.addr"
        ip link set dev "$iface" master "$LAN_BRIDGE"
    fi
    # Android's IpServer may re-add its 42-49.x IPv4 address after an upstream
    # change. Keep IPv4 DHCP/routing on RouterOS, but retain Android's global
    # IPv6 address so its cellular RA and IPv6 forwarding continue to work.
    ip -4 addr flush dev "$iface" 2>/dev/null || true
    ip link set dev "$iface" up
}

bridge_detach() {
    iface="$1"
    [ -e "/sys/class/net/$iface" ] || return 0
    if [ -e "$VM_DIR/bridge-$iface.connector" ]; then
        tag="$(printf '%s' "$iface" | tr -cd 'A-Za-z0-9' | cut -c1-7)"
        ip link delete "rosx-${tag}h" 2>/dev/null || true
        if [ -s "$VM_DIR/bridge-$iface.addr" ]; then
            while read -r saved_addr; do
                [ -n "$saved_addr" ] && ip -4 addr add "$saved_addr" dev "$iface" 2>/dev/null || true
            done < "$VM_DIR/bridge-$iface.addr"
        fi
        rm -f "$VM_DIR/bridge-$iface.addr" "$VM_DIR/bridge-$iface.connector"
        return 0
    fi
    current_master="$(basename "$(readlink "/sys/class/net/$iface/master" 2>/dev/null)" 2>/dev/null)"
    [ "$current_master" = "$LAN_BRIDGE" ] || return 0
    ip link set dev "$iface" nomaster
    if [ -s "$VM_DIR/bridge-$iface.addr" ]; then
        while read -r saved_addr; do
            [ -n "$saved_addr" ] && ip -4 addr add "$saved_addr" dev "$iface" 2>/dev/null || true
        done < "$VM_DIR/bridge-$iface.addr"
    fi
    rm -f "$VM_DIR/bridge-$iface.addr"
}

sync_bridge_ports() {
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        if is_tether_candidate "$iface"; then
            bridge_attach "$iface"
        elif [ -e "$VM_DIR/bridge-$iface.addr" ] || \
                [ -e "$VM_DIR/bridge-$iface.connector" ]; then
            bridge_detach "$iface"
        fi
    done
}

ensure_ros_routes() {
    if [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        ip route replace "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE" table "$ROS_TABLE"
        ip route replace default via "$LAN_GUEST_IP" dev "$LAN_BRIDGE" onlink table "$ROS_TABLE"
    else
        ip route replace "$LAN_SUBNET" dev "$LAN_BRIDGE" table "$ROS_TABLE"
        ip route replace default via "$LAN_GUEST_IP" dev "$LAN_BRIDGE" table "$ROS_TABLE"
    fi
    ip route replace "$WAN_SUBNET" dev "$WAN_TAP" table "$ROS_TABLE"
}

clear_routed_tethers() {
    while ip -4 rule del priority "$ROUTED_TETHER_RULE_PRIO" 2>/dev/null; do :; done
    delete_jump_and_chain nat PREROUTING ROS_RPRE
    rm -f "$ROUTED_IFACES_FILE"
}

stop_dhcp_relay() {
    iface="$1"
    pidfile="$VM_DIR/dhcp-relay-$iface.pid"
    if [ -r "$pidfile" ]; then
        relay_pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$relay_pid" ] && [ -r "/proc/$relay_pid/cmdline" ] && \
                tr '\000' ' ' < "/proc/$relay_pid/cmdline" | grep -q "$DHCP_RELAY"; then
            kill "$relay_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pidfile"
}

restore_proxyarp_iface() {
    iface="$1"
    stop_dhcp_relay "$iface"
    ip route del "$LAN_SUBNET" dev "$iface" metric 42700 2>/dev/null || true
    saved="$VM_DIR/proxyarp-$iface.original"
    if [ -r "$saved" ] && [ -w "/proc/sys/net/ipv4/conf/$iface/proxy_arp" ]; then
        cat "$saved" > "/proc/sys/net/ipv4/conf/$iface/proxy_arp"
    fi
    rm -f "$saved"
}

clear_proxyarp_tethers() {
    if [ -r "$PROXYARP_IFACES_FILE" ]; then
        while read -r iface; do
            [ -n "$iface" ] && restore_proxyarp_iface "$iface"
        done < "$PROXYARP_IFACES_FILE"
    fi
    for pidfile in "$VM_DIR"/dhcp-relay-*.pid; do
        [ -e "$pidfile" ] || continue
        iface="${pidfile##*/dhcp-relay-}"
        iface="${iface%.pid}"
        stop_dhcp_relay "$iface"
    done
    saved="$VM_DIR/proxyarp-$LAN_BRIDGE.original"
    if [ -r "$saved" ] && [ -w "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" ]; then
        cat "$saved" > "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp"
    fi
    rm -f "$saved" "$PROXYARP_IFACES_FILE"
    ip route del "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE" 2>/dev/null || true
}

ensure_dhcp_relay() {
    iface="$1"
    pidfile="$VM_DIR/dhcp-relay-$iface.pid"
    if [ -r "$pidfile" ]; then
        relay_pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$relay_pid" ] && [ -r "/proc/$relay_pid/cmdline" ] && \
                tr '\000' ' ' < "/proc/$relay_pid/cmdline" | grep -Fq "$DHCP_RELAY $iface $LAN_TAP"; then
            return 0
        fi
    fi
    stop_dhcp_relay "$iface"
    nohup "$DHCP_RELAY" "$iface" "$LAN_TAP" \
        </dev/null >"$VM_DIR/dhcp-relay-$iface.log" 2>&1 &
    echo "$!" > "$pidfile"
}

sync_proxyarp_tethers() {
    desired="$VM_DIR/proxyarp-tethers.next"
    : > "$desired"
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        echo "$iface" >> "$desired"
    done

    if [ -r "$PROXYARP_IFACES_FILE" ]; then
        while read -r iface; do
            [ -n "$iface" ] || continue
            grep -Fxq "$iface" "$desired" 2>/dev/null || restore_proxyarp_iface "$iface"
        done < "$PROXYARP_IFACES_FILE"
    fi

    clear_routed_tethers
    ensure_ros_routes
    ip route replace "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE"
    saved="$VM_DIR/proxyarp-$LAN_BRIDGE.original"
    if [ ! -r "$saved" ]; then
        cat "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" > "$saved"
    fi
    echo 1 > "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp"

    while read -r iface; do
        [ -n "$iface" ] || continue
        saved="$VM_DIR/proxyarp-$iface.original"
        if [ ! -r "$saved" ]; then
            cat "/proc/sys/net/ipv4/conf/$iface/proxy_arp" > "$saved"
        fi
        echo 1 > "/proc/sys/net/ipv4/conf/$iface/proxy_arp"
        # The /32 keeps RouterOS itself on ros-br; the less-specific route
        # sends all leased clients back to the untouched Android tether port.
        ip route replace "$LAN_SUBNET" dev "$iface" metric 42700
        ip -4 rule add priority "$ROUTED_TETHER_RULE_PRIO" iif "$iface" lookup "$ROS_TABLE"
        ensure_dhcp_relay "$iface"
    done < "$desired"
    mv -f "$desired" "$PROXYARP_IFACES_FILE"
}

sync_routed_tethers() {
    desired=""
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        desired="${desired}${iface}
"
    done
    clear_proxyarp_tethers
    clear_routed_tethers
    ensure_ros_routes
    iptables -t nat -N ROS_RPRE 2>/dev/null || true
    iptables -t nat -F ROS_RPRE
    printf '%s' "$desired" | while read -r iface; do
        [ -n "$iface" ] || continue
        ip -4 rule add priority "$ROUTED_TETHER_RULE_PRIO" iif "$iface" lookup "$ROS_TABLE"
        # Android advertises itself as DNS. Send client DNS to RouterOS so its
        # dnsmasq/PassWall policy is still applied in routed fallback mode.
        iptables -t nat -A ROS_RPRE -i "$iface" -p udp --dport 53 \
            -j DNAT --to-destination "$LAN_GUEST_IP:53"
        iptables -t nat -A ROS_RPRE -i "$iface" -p tcp --dport 53 \
            -j DNAT --to-destination "$LAN_GUEST_IP:53"
    done
    ensure_jump nat PREROUTING ROS_RPRE
    printf '%s' "$desired" > "$ROUTED_IFACES_FILE"
}

save_direct_br0_state() {
    [ -d "/sys/class/net/$NATIVE_TETHER_BRIDGE/bridge" ] || \
        die "native tether bridge does not exist: $NATIVE_TETHER_BRIDGE"
    # The browser supplies UFI_DATA.lan_ipaddr as LAN_HOST_IP. Never rewrite
    # br0: losing this address would also disconnect the UFI management UI.
    ip -4 -o addr show dev "$NATIVE_TETHER_BRIDGE" 2>/dev/null | \
        awk '{print $4}' | grep -Fxq "$LAN_HOST_IP/24" || \
        die "$NATIVE_TETHER_BRIDGE does not own protected UFI address $LAN_HOST_IP/24"
}

restart_android_tether_dns() {
    command -v ndc >/dev/null 2>&1 || return 0
    ndc tether status 2>/dev/null | grep -q 'Tethering services started' || return 0
    if ! ndc tether stop >/dev/null 2>&1 || ! ndc tether start >/dev/null 2>&1; then
        echo "routeros: warning: could not restart Android tether DNS" >&2
        return 1
    fi
}

sync_direct_br0() {
    save_direct_br0_state
    clear_routed_tethers
    clear_proxyarp_tethers
    [ -e "/sys/class/net/$LAN_TAP" ] || return 0
    current_master="$(basename "$(readlink "/sys/class/net/$LAN_TAP/master" 2>/dev/null)" 2>/dev/null)"
    if [ "$current_master" != "$NATIVE_TETHER_BRIDGE" ]; then
        ip link set dev "$LAN_TAP" nomaster 2>/dev/null || true
        ip link set dev "$LAN_TAP" master "$NATIVE_TETHER_BRIDGE"
    fi
    ip link set dev "$LAN_TAP" up
    ip link set dev "$NATIVE_TETHER_BRIDGE" up
    # LAN_HOST_IP is Android/UFI's existing address, while LAN_GUEST_IP is
    # RouterOS/LuCI. Both share this L2 segment; br0 itself remains untouched.
    save_direct_br0_state
}

restore_direct_br0() {
    ip link set dev "$LAN_TAP" nomaster 2>/dev/null || true
    rm -f "$DIRECT_BR0_ADDR_FILE"
}

# ---- stopped-VM transition (directbr0) ----
# After the VM stops, clients that still hold RouterOS's lease keep using
# LAN_GUEST_IP (e.g. 192.168.0.254) as gateway/DNS.  The guest is gone, so
# without a stand-in they lose internet until a replug/reconnect forces a new
# lease.  Make the host impersonate the dead guest: own the /32 on lo, answer
# proxy ARP on the native bridge, and DNAT old-DNS queries to Android's
# upstream.  Clients keep working and migrate to native DHCP at renewal.
capture_stopped_transition_dns() {
    dns="$(dumpsys tethering 2>/dev/null | \
        sed -n 's/.*SET DNS forwarders: network=[0-9][0-9]* dnsServers=\[\([^]]*\)\].*/\1/p' | \
        tail -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    [ -n "$dns" ] || dns="$(dumpsys connectivity 2>/dev/null | \
        grep -oE 'DnsAddresses: \[[^]]*' | head -1 | \
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    [ -n "$dns" ] || dns="$(getprop net.dns1 2>/dev/null | tr -d '\r' | \
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')"
    printf '%s\n' "$dns" > "$STOP_TRANSITION_DNS_FILE"
}

clear_stopped_transition() {
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] || return 0
    ip -4 addr del "$LAN_GUEST_IP/32" dev lo 2>/dev/null || true
    ip neigh del proxy "$LAN_GUEST_IP" dev "$LAN_BRIDGE" 2>/dev/null || true
    saved="$VM_DIR/proxyarp-$LAN_BRIDGE.stopped"
    if [ -r "$saved" ] && [ -w "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" ]; then
        cat "$saved" > "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp"
    fi
    rm -f "$saved"
    delete_jump_and_chain nat PREROUTING ROS_STOP_PRE
    rm -f "$STOP_TRANSITION_DNS_FILE"
}

setup_stopped_transition() {
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] || return 0
    [ -d "/sys/class/net/$LAN_BRIDGE/bridge" ] || return 0
    # The host takes over the guest IP so old gateway/DNS packets are local.
    ip -4 addr add "$LAN_GUEST_IP/32" dev lo 2>/dev/null || true
    saved="$VM_DIR/proxyarp-$LAN_BRIDGE.stopped"
    if [ ! -r "$saved" ]; then
        cat "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" > "$saved" 2>/dev/null || true
    fi
    echo 1 > "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" 2>/dev/null || true
    ip neigh del proxy "$LAN_GUEST_IP" dev "$LAN_BRIDGE" 2>/dev/null || true
    ip neigh add proxy "$LAN_GUEST_IP" dev "$LAN_BRIDGE" 2>/dev/null || true
    # Flush clients' stale ARP cache pointing at the vanished guest MAC;
    # otherwise their frames are dropped at L2 until ARP expiry (~30-60s).
    if [ -x "$GARP" ]; then
        "$GARP" "$LAN_BRIDGE" "$LAN_GUEST_IP" 3 2>/dev/null || true
    fi
    capture_stopped_transition_dns
    dns="$(cat "$STOP_TRANSITION_DNS_FILE" 2>/dev/null)"
    case "$dns" in
        ''|*[!0-9.]*) return 0 ;;
    esac
    iptables -t nat -N ROS_STOP_PRE 2>/dev/null || true
    iptables -t nat -F ROS_STOP_PRE
    iptables -t nat -A ROS_STOP_PRE -i "$LAN_BRIDGE" -d "$LAN_GUEST_IP" \
        -p udp --dport 53 -j DNAT --to-destination "$dns:53"
    iptables -t nat -A ROS_STOP_PRE -i "$LAN_BRIDGE" -d "$LAN_GUEST_IP" \
        -p tcp --dport 53 -j DNAT --to-destination "$dns:53"
    ensure_jump nat PREROUTING ROS_STOP_PRE
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
}

# Wait until RouterOS's LAN bridge is forwarding so it answers ARP/ping and
# serves DHCP on the shared bridge.  The fresh console log records the
# guest LAN answering ARP/ping; console log is a fallback.
wait_for_guest_lan() {
    wait_count=0
    while [ "$wait_count" -lt 30 ]; do
        if ping -I "$LAN_BRIDGE" -c 1 -W 1 "$LAN_GUEST_IP" >/dev/null 2>&1; then
            sleep 1
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    return 1
}

# Mirror of the stop-side handoff.  The stopped transition pointed clients'
# ARP cache for LAN_GUEST_IP at this host; once the guest is back on the
# bridge, announce the guest's MAC so clients immediately switch back.
# USB, 转网口 and hotspot all share the same bridge, so a broadcast GARP is
# enough -- no interface bounce and no DHCP kick.
announce_guest_mac() {
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] || return 0
    [ -d "/sys/class/net/$LAN_BRIDGE/bridge" ] || return 0
    [ -x "$GARP" ] || return 0
    # Resolve the guest from the host so its MAC lands in the neighbour table.
    # Note: this iproute2 prints "IP lladdr MAC STATE" without the dev field,
    # so extract the MAC by pattern instead of by fixed column.
    ping -I "$LAN_BRIDGE" -c 1 -W 1 "$LAN_GUEST_IP" >/dev/null 2>&1 || true
    guest_mac="$(ip neigh show "$LAN_GUEST_IP" dev "$LAN_BRIDGE" 2>/dev/null | \
        sed -n 's/.*lladdr \([0-9a-fA-F:]\{17\}\).*/\1/p' | head -1)"
    case "$guest_mac" in
        [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
        *) return 0 ;;
    esac
    "$GARP" "$LAN_BRIDGE" "$LAN_GUEST_IP" 3 "$guest_mac" 2>/dev/null || true
}

sync_tether_network() {
    [ "${STANDALONE:-0}" = 1 ] && return 0
    case "$EFFECTIVE_TETHER_MODE" in
        routed) sync_routed_tethers ;;
        proxyarp) sync_proxyarp_tethers ;;
        directbr0) sync_direct_br0 ;;
        *) sync_bridge_ports ;;
    esac
}

cellular_ipv6_prefix() {
    ip -6 -o addr show dev "$CELLULAR_IFACE" scope global 2>/dev/null | awk '
        NR == 1 {
            split($4, cidr, "/")
            split(cidr[1], h, ":")
            if (h[1] != "" && h[2] != "" && h[3] != "" && h[4] != "")
                print h[1] ":" h[2] ":" h[3] ":" h[4] "::"
        }'
}

stop_ra6_port() {
    iface="$1"
    pidfile="$VM_DIR/ra6-$iface.pid"
    if [ -r "$pidfile" ]; then
        ra_pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$ra_pid" ] && [ -r "/proc/$ra_pid/cmdline" ] && \
                tr '\000' ' ' < "/proc/$ra_pid/cmdline" | grep -q "$RA6"; then
            kill "$ra_pid" 2>/dev/null || true
            # ra6 sends withdrawal advertisements on SIGTERM. Wait for those
            # frames before a replacement announces a new prefix, otherwise
            # a late withdrawal could invalidate the new default route.
            wait_count=0
            while [ "$wait_count" -lt 20 ] && [ -e "/proc/$ra_pid" ]; do
                sleep 0.1
                wait_count=$((wait_count + 1))
            done
        fi
    fi
    rm -f "$pidfile"
}

stop_ipv6_downstream() {
    for path in "$VM_DIR"/ra6-*.pid; do
        [ -e "$path" ] || continue
        iface="${path##*/ra6-}"
        iface="${iface%.pid}"
        stop_ra6_port "$iface"
    done
    while ip -6 rule del priority "$IPV6_OUT_RULE_PRIO" 2>/dev/null; do :; done
    while ip -6 rule del priority "$IPV6_IN_RULE_PRIO" 2>/dev/null; do :; done
    old_prefix="$(cat "$IPV6_PREFIX_FILE" 2>/dev/null)"
    [ -n "$old_prefix" ] && ip -6 route del "$old_prefix/64" dev "$LAN_BRIDGE" table main 2>/dev/null || true
    [ -n "$old_prefix" ] && ip -6 route del "$old_prefix/64" dev "$WAN_TAP" table main 2>/dev/null || true
    ip -6 addr del fe80::1/64 dev "$LAN_BRIDGE" 2>/dev/null || true
    ip -6 addr del fe80::1/64 dev "$WAN_TAP" 2>/dev/null || true
    delete_ip6_jump_and_chain FORWARD "$IPV6_FORWARD_CHAIN"
    delete_ip6_jump_and_chain OUTPUT ROS6_OUT
    rm -f "$IPV6_PREFIX_FILE"
}

ensure_ra6_port() {
    iface="$1"
    prefix="$2"
    router_iface="${3:-$LAN_BRIDGE}"
    pidfile="$VM_DIR/ra6-$iface.pid"
    if [ -r "$pidfile" ]; then
        ra_pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$ra_pid" ] && [ -d "/proc/$ra_pid" ] && return 0
    fi
    stop_ra6_port "$iface"
    # Advertise the bridge itself as the preferred router. Android may also
    # publish its physical-port router as a medium-preference fallback.
    nohup "$RA6" "$iface" "$router_iface" "$prefix" \
        </dev/null >"$VM_DIR/ra6-$iface.log" 2>&1 &
    echo "$!" > "$pidfile"
}

sync_ipv6_passthrough() {
    # Android owns downstream IPv6 in this mode; do not suppress its native
    # tethering RA/DHCPv6 packets.
    delete_ip6_jump_and_chain OUTPUT ROS6_OUT
    [ -x "$RA6" ] || return 0
    prefix="$(cellular_ipv6_prefix)"
    if [ -z "$prefix" ]; then
        stop_ipv6_downstream
        return 0
    fi

    current_prefix="$(cat "$IPV6_PREFIX_FILE" 2>/dev/null)"
    if [ "$current_prefix" != "$prefix" ]; then
        stop_ipv6_downstream
        ip -6 addr replace fe80::1/64 dev "$LAN_BRIDGE"
        ip -6 route replace "$prefix/64" dev "$LAN_BRIDGE" metric 64 table main
        ip -6 rule add priority "$IPV6_OUT_RULE_PRIO" iif "$LAN_BRIDGE" lookup "$CELLULAR_ROUTE_TABLE"
        ip -6 rule add priority "$IPV6_IN_RULE_PRIO" iif "$CELLULAR_IFACE" to "$prefix/64" lookup main
        echo "$prefix" > "$IPV6_PREFIX_FILE"
    fi

    active_ra="$VM_DIR/ra6-active"
    : > "$active_ra"
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        if [ -d "$path/bridge" ]; then
            for member_path in "$path"/brif/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                case "$member" in rosx-*) continue ;; esac
                ensure_ra6_port "$member" "$prefix"
                echo "$member" >> "$active_ra"
            done
        else
            current_master="$(basename "$(readlink "$path/master" 2>/dev/null)" 2>/dev/null)"
            if [ "$current_master" = "$LAN_BRIDGE" ]; then
                ensure_ra6_port "$iface" "$prefix"
                echo "$iface" >> "$active_ra"
            fi
        fi
    done
    for pidfile in "$VM_DIR"/ra6-*.pid; do
        [ -e "$pidfile" ] || continue
        iface="${pidfile##*/ra6-}"
        iface="${iface%.pid}"
        grep -Fxq "$iface" "$active_ra" 2>/dev/null || stop_ra6_port "$iface"
    done
    rm -f "$active_ra"
}


sync_managed_ipv6_ra_block() {
    ip6tables -N ROS6_OUT 2>/dev/null || true
    ip6tables -F ROS6_OUT
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        ip6tables -A ROS6_OUT -o "$iface" -p ipv6-icmp --icmpv6-type 134 -j DROP
        ip6tables -A ROS6_OUT -o "$iface" -p udp --sport 547 --dport 546 -j DROP
        if [ -d "$path/bridge" ]; then
            for member_path in "$path"/brif/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                case "$member" in rosx-*) continue ;; esac
                ip6tables -A ROS6_OUT -o "$member" -p ipv6-icmp --icmpv6-type 134 -j DROP
                ip6tables -A ROS6_OUT -o "$member" -p udp --sport 547 --dport 546 -j DROP
            done
        fi
    done
    ensure_ip6_jump OUTPUT ROS6_OUT
}


withdraw_native_ipv6_ra() {
    prefix="$1"
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        # Send one advertisement followed immediately by the helper's normal
        # zero-lifetime withdrawal, using Android's own interface link-local.
        # This removes routes/addresses cached before the managed-mode filter
        # was installed, so clients do not need to reconnect manually.
        "$RA6" "$iface" "$iface" "$prefix" \
            >"$VM_DIR/withdraw-$iface.log" 2>&1 &
        withdraw_pid=$!
        sleep 1
        kill "$withdraw_pid" 2>/dev/null || true
        wait "$withdraw_pid" 2>/dev/null || true
    done
}


sync_ipv6_managed() {
    [ -x "$RA6" ] || return 0
    prefix="$(cellular_ipv6_prefix)"
    if [ -z "$prefix" ]; then
        stop_ipv6_downstream
        return 0
    fi

    current_prefix="$(cat "$IPV6_PREFIX_FILE" 2>/dev/null)"
    if [ "$current_prefix" != "$prefix" ]; then
        stop_ipv6_downstream
        # RouterOS learns a public WAN address and default route from this RA.
        # Its own firewall performs NAT66 from the managed LAN ULA. Android
        # only routes that public WAN address to the cellular network.
        ip -6 addr replace fe80::1/64 dev "$WAN_TAP"
        ip -6 route replace "$prefix/64" dev "$WAN_TAP" metric 64 table main
        ip -6 rule add priority "$IPV6_OUT_RULE_PRIO" iif "$WAN_TAP" lookup "$CELLULAR_ROUTE_TABLE"
        ip -6 rule add priority "$IPV6_IN_RULE_PRIO" iif "$CELLULAR_IFACE" to "$prefix/64" lookup main
        echo "$prefix" > "$IPV6_PREFIX_FILE"
        sync_managed_ipv6_ra_block
        withdraw_native_ipv6_ra "$prefix"
    fi

    ip6tables -N "$IPV6_FORWARD_CHAIN" 2>/dev/null || true
    ip6tables -F "$IPV6_FORWARD_CHAIN"
    ip6tables -A "$IPV6_FORWARD_CHAIN" -i "$WAN_TAP" -j ACCEPT
    ip6tables -A "$IPV6_FORWARD_CHAIN" -o "$WAN_TAP" -j ACCEPT
    ensure_ip6_jump FORWARD "$IPV6_FORWARD_CHAIN"
    sync_managed_ipv6_ra_block
    ensure_ra6_port "$WAN_TAP" "$prefix" "$WAN_TAP"
}

sync_routed_ipv6_policy() {
    delete_ip6_jump_and_chain FORWARD ROS6_ROUTED
    [ "$IPV6_PASSTHROUGH" = 1 ] && return 0
    ip6tables -N ROS6_ROUTED 2>/dev/null || true
    ip6tables -F ROS6_ROUTED
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        ip6tables -A ROS6_ROUTED -i "$iface" -j REJECT
        ip6tables -A ROS6_ROUTED -o "$iface" -j REJECT
    done
    ensure_ip6_jump FORWARD ROS6_ROUTED
}

sync_ipv6_downstream() {
    [ "${STANDALONE:-0}" = 1 ] && return 0
    # The safe routed/proxy-ARP modes cannot advertise RouterOS's LAN prefix
    # without extending br0. Honour the switch by passing Android IPv6 at 1
    # and blocking downstream IPv6 at 0 so it cannot silently bypass RouterOS.
    if [ "$EFFECTIVE_TETHER_MODE" = routed ] || [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        sync_routed_ipv6_policy
        return 0
    fi
    if [ "$IPV6_PASSTHROUGH" = 1 ]; then
        sync_ipv6_passthrough
    else
        sync_ipv6_managed
    fi
}

refresh_ipv6() {
    load_config
    resolve_device_config
    stop_ipv6_downstream
    is_running && sync_ipv6_downstream
    echo "IPv6 fallback RA refreshed"
}

detach_bridge_ports() {
    clear_routed_tethers
    clear_proxyarp_tethers
    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        restore_direct_br0
        return 0
    fi
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        bridge_detach "$iface"
    done
}

# Android keeps default routes in per-network tables, not in the main table.
# Route packets arriving from RouterOS's WAN out through whichever table has the
# active IPv4 default, so NAT mode works on WiFi, USB or cellular upstream.
current_upstream_table() {
    ip -4 route show table all 2>/dev/null | awk -v ros_table="$ROS_TABLE" '
        /^default / {
            table = ""
            dev = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "table") table = $(i + 1)
                if ($i == "dev") dev = $(i + 1)
            }
            if (table != "" && table != ros_table && table != "dummy0" &&
                    dev != "ros-wan" && dev != "ros-lan" && dev != "ros-br") {
                print table
                exit
            }
        }'
}

sync_upstream() {
    force_refresh="${1:-0}"
    # Android keeps the active Wi-Fi/cellular default in a named table. Wi-Fi
    # uses "default via ...", while this Unisoc cellular driver uses
    # "default dev ...", so accept both and ignore dummy/VM tables.
    upstream="$(current_upstream_table)"
    [ -n "$upstream" ] || return 0
    current_upstream="$(ip -4 rule show priority "$UPSTREAM_RULE_PRIO" 2>/dev/null | awk '{print $NF; exit}')"
    [ "$force_refresh" != 1 ] && [ "$current_upstream" = "$upstream" ] && return 0
    while ip rule del priority "$UPSTREAM_RULE_PRIO" 2>/dev/null; do :; done
    ip rule add priority "$UPSTREAM_RULE_PRIO" iif "$WAN_TAP" lookup "$upstream"
}

sync_dhcp_block() {
    [ "${STANDALONE:-0}" = 1 ] && return 0
    if [ "$EFFECTIVE_TETHER_MODE" = routed ]; then
        delete_jump_and_chain filter OUTPUT ROS_OUT
        return 0
    fi
    iptables -N ROS_OUT 2>/dev/null || true
    iptables -F ROS_OUT
    iptables -A ROS_OUT -o "$LAN_BRIDGE" -p udp --sport 67 --dport 68 -j DROP
    if [ "$TETHER_IFACE_PATTERNS" = auto ]; then
        # A trailing '+' is iptables' interface-prefix wildcard and remains
        # effective even while gadget reconfiguration removes the netdev.
        for iface_prefix in sipa_usb+ rndis+ wlan+ softap+ ap_br_wlan+ ap_br_softap+; do
            iptables -A ROS_OUT -o "$iface_prefix" -p udp --sport 67 --dport 68 -j DROP
        done
        iptables -A ROS_OUT -o bt-pan -p udp --sport 67 --dport 68 -j DROP
    fi
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_capable "$iface" || continue
        iptables -A ROS_OUT -o "$iface" -p udp --sport 67 --dport 68 -j DROP
        if [ -d "$path/bridge" ]; then
            for member_path in "$path"/brif/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                iptables -A ROS_OUT -o "$member" -p udp --sport 67 --dport 68 -j DROP
            done
        fi
    done
    ensure_jump filter OUTPUT ROS_OUT
}

setup_network() {
    echo "$EFFECTIVE_TETHER_MODE" > "$ACTIVE_MODE_FILE"
    clear_stopped_transition
    # Install the DHCP guard before TAP/bridge changes close the lifecycle race.
    sync_dhcp_block
    for tap in "$WAN_TAP" "$LAN_TAP"; do
        ip link set dev "$tap" nomaster 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || ip link delete "$tap" 2>/dev/null || true
        if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ]; then
            if ! ip tuntap add dev "$tap" mode tap multi_queue 2>/dev/null; then
                if [ "$VM_NET_QUEUES" = auto ]; then
                    echo "routeros: multiqueue TAP unavailable; falling back to one queue" >&2
                    EFFECTIVE_NET_QUEUES=1
                    ip tuntap add dev "$tap" mode tap
                else
                    die "cannot create multiqueue TAP $tap"
                fi
            fi
        else
            ip tuntap add dev "$tap" mode tap
        fi
    done
    ip addr flush dev "$WAN_TAP" 2>/dev/null
    ip addr add "$WAN_HOST_IP/24" dev "$WAN_TAP"
    ip link set "$WAN_TAP" up

    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        save_direct_br0_state
        ip addr flush dev "$LAN_TAP" 2>/dev/null
        ip link set "$LAN_TAP" up
        sync_direct_br0
    else
        ip link add name "$LAN_BRIDGE" type bridge 2>/dev/null || true
        ip link set dev "$LAN_BRIDGE" address 02:00:00:00:88:02
        ip link set "$LAN_BRIDGE" up
        ip addr flush dev "$LAN_TAP" 2>/dev/null
        ip link set "$LAN_TAP" up
        ip link set dev "$LAN_TAP" master "$LAN_BRIDGE"
        ip addr flush dev "$LAN_BRIDGE" 2>/dev/null
        if [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
            ip addr add "$LAN_HOST_IP/32" dev "$LAN_BRIDGE"
        else
            ip addr add "$LAN_HOST_IP/24" dev "$LAN_BRIDGE"
        fi
        sync_tether_network
    fi
    sync_ipv6_downstream

    # Let the Android host itself reach the RouterOS subnets (default policy
    # routing would otherwise drop these via the trailing "unreachable" rule).
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    ip rule add priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main
    ip rule add priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main

    # Send RouterOS's WAN traffic out the device's active upstream.
    sync_upstream

    if [ ! -f "$VM_DIR/ip_forward.original" ]; then
        cat /proc/sys/net/ipv4/ip_forward > "$VM_DIR/ip_forward.original"
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward

    iptables -N ROS_FWD 2>/dev/null || true
    iptables -F ROS_FWD
    iptables -A ROS_FWD -i "$WAN_TAP" -j ACCEPT
    iptables -A ROS_FWD -o "$WAN_TAP" -j ACCEPT
    iptables -A ROS_FWD -i "$LAN_TAP" -j ACCEPT
    iptables -A ROS_FWD -o "$LAN_TAP" -j ACCEPT
    iptables -A ROS_FWD -i "$LAN_BRIDGE" -j ACCEPT
    iptables -A ROS_FWD -o "$LAN_BRIDGE" -j ACCEPT
    ensure_jump filter FORWARD ROS_FWD

    iptables -t nat -N ROS_POST 2>/dev/null || true
    iptables -t nat -F ROS_POST
    iptables -t nat -A ROS_POST -s "$WAN_SUBNET" -j MASQUERADE
    # DNAT reply path: rewrite the source to the host LAN IP so the guest
    # sees a LAN-originated connection and replies symmetrically via the guest LAN.
    # Without this the guest routes replies out its WAN (default route) and
    # the host never completes the handshake.
    # All traffic routed into RouterOS's LAN is represented by the Android-side
    # LAN address. This gives Android apps and tethered clients a symmetric
    # return path through conntrack, including apps bound to Wi-Fi/cellular.
    iptables -t nat -A ROS_POST ! -s "$LAN_SUBNET" -o "$LAN_BRIDGE" -j SNAT --to-source "$LAN_HOST_IP"
    ensure_jump nat POSTROUTING ROS_POST

    iptables -t nat -N ROS_PRE 2>/dev/null || true
    iptables -t nat -F ROS_PRE
    # External SSH (host 2223 -> RouterOS LAN 88.1:22) and LuCI web
    # (host 8080 -> 88.1:80). The LAN side is used so RouterOS default
    # firewall (lan input ACCEPT) applies; ROS_POST rewrites the source to
    # 88.2 so replies come back through the LAN side. legacy iptables rejects
    # multiple -i flags in one rule, so skip the taps with RETURN first.
    iptables -t nat -A ROS_PRE -p tcp -i "$WAN_TAP" -j RETURN
    iptables -t nat -A ROS_PRE -p tcp -i "$LAN_TAP" -j RETURN
    iptables -t nat -A ROS_PRE -p tcp --dport "$SSH_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:22"
    iptables -t nat -A ROS_PRE -p tcp --dport "$WEB_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:80"
    ensure_jump nat PREROUTING ROS_PRE

    # Android owns AP/RNDIS lifecycle. Bridge mode moves DHCP/RA to RouterOS;
    # Routed fallback retains Android DHCP. Proxy-ARP and bridge modes suppress
    # Android DHCP so RouterOS is the only server clients can hear.
    sync_dhcp_block

}

teardown_network() {
    untakeover
    # crosvm USB attachments die with the process; unbind any drivers we
    # took from Android and hand the devices back to the host.
    usb_restore_all
    stop_ipv6_downstream
    ip rule del priority "$UPSTREAM_RULE_PRIO" 2>/dev/null || true
    detach_bridge_ports
    ip route flush table "$ROS_TABLE" 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    delete_jump_and_chain filter FORWARD ROS_FWD
    delete_jump_and_chain nat POSTROUTING ROS_POST
    delete_jump_and_chain nat PREROUTING ROS_PRE
    delete_jump_and_chain filter OUTPUT ROS_OUT
    delete_ip6_jump_and_chain OUTPUT ROS6_OUT
    delete_ip6_jump_and_chain FORWARD ROS6_ROUTED
    ip link set "$LAN_TAP" nomaster 2>/dev/null || true
    if [ "$EFFECTIVE_TETHER_MODE" != directbr0 ]; then
        ip link set "$LAN_BRIDGE" down 2>/dev/null || true
        ip link delete "$LAN_BRIDGE" type bridge 2>/dev/null || true
    fi
    for tap in "$WAN_TAP" "$LAN_TAP"; do
        ip link set "$tap" down 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || ip link delete "$tap" 2>/dev/null || true
    done
    if [ -r "$VM_DIR/ip_forward.original" ]; then
        cat "$VM_DIR/ip_forward.original" > /proc/sys/net/ipv4/ip_forward
        rm -f "$VM_DIR/ip_forward.original"
    fi
    rm -f "$ACTIVE_MODE_FILE"
    # Hand old-lease clients back to the host after the guest is gone.
    setup_stopped_transition
}

# Steer Android's own locally generated traffic through RouterOS. Tethered
# clients use either a real Layer-2 bridge or their mode-specific ingress rule.
takeover() {
    [ "${STANDALONE:-0}" = 1 ] && { echo "standalone mode: Android traffic takeover disabled"; return 0; }
    ip link show "$LAN_TAP" >/dev/null 2>&1 || die "run start first"

    ip route flush table "$ROS_TABLE" 2>/dev/null || true
    ensure_ros_routes

    while ip -4 rule del priority "$RULE_PRIO" 2>/dev/null; do :; done
    ip rule add priority "$RULE_PRIO" iif lo lookup "$ROS_TABLE"

    # RouterOS takeover currently covers Android's local IPv4 only. Reject the
    # Android host's own IPv6 while takeover is active; bridged hotspot/USB
    # clients keep using Android's cellular IPv6 service.
    while ip -6 rule del priority "$IPV6_BLOCK_PRIO" 2>/dev/null; do :; done
    ip -6 rule add priority "$IPV6_BLOCK_PRIO" iif lo prohibit
    delete_ip6_jump_and_chain FORWARD ROS6_FWD

    touch "$TAKEOVER_FLAG"
    sync_upstream
    start_monitor
    echo "RouterOS takeover enabled (Android apps routed; tether mode $EFFECTIVE_TETHER_MODE)"
}

untakeover() {
    rm -f "$TAKEOVER_FLAG"
    while ip -4 rule del priority "$RULE_PRIO" 2>/dev/null; do :; done
    while ip -6 rule del priority "$IPV6_BLOCK_PRIO" 2>/dev/null; do :; done
    if [ "$EFFECTIVE_TETHER_MODE" = routed ] || [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        ensure_ros_routes
    else
        ip route flush table "$ROS_TABLE" 2>/dev/null || true
    fi
    delete_ip6_jump_and_chain FORWARD ROS6_FWD
    echo "RouterOS takeover disabled"
}

network_monitor() {
    [ "${STANDALONE:-0}" = 1 ] && exit 0
    if [ -r "$MONITOR_PIDFILE" ]; then
        monitor_pid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"
        if [ -n "$monitor_pid" ] && [ "$monitor_pid" != "$$" ] && [ -d "/proc/$monitor_pid" ]; then
            return 0
        fi
    fi
    load_config
    resolve_device_config
    use_active_tether_mode
    if [ -r "$MONITOR_PIDFILE" ]; then
        monitor_pid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"
        if [ -n "$monitor_pid" ] && [ "$monitor_pid" != "$$" ] && [ -d "/proc/$monitor_pid" ]; then
            return 0
        fi
    fi
    echo "$$" > "$MONITOR_PIDFILE"
    trap 'rm -f "$MONITOR_PIDFILE"' EXIT
    trap 'exit 0' HUP TERM

    network_helper_state() {
        for pidfile in "$VM_DIR"/ra6-*.pid "$VM_DIR"/dhcp-relay-*.pid; do
            [ -e "$pidfile" ] || continue
            helper_pid="$(cat "$pidfile" 2>/dev/null)"
            helper_name="${pidfile##*/}"
            if [ -n "$helper_pid" ] && [ -d "/proc/$helper_pid" ]; then
                printf 'helper %s up\n' "$helper_name"
            else
                printf 'helper %s down\n' "$helper_name"
            fi
        done
    }

    direct_br0_carrier_state() {
        DIRECT_UPSTREAM_TABLE="$(current_upstream_table)"
        DIRECT_UPSTREAM_RULE="$(ip -4 rule show priority "$UPSTREAM_RULE_PRIO" 2>/dev/null | awk '{print $NF; exit}')"
        DIRECT_UPSTREAM_ROUTE=""
        if [ -n "$DIRECT_UPSTREAM_TABLE" ]; then
            DIRECT_UPSTREAM_ROUTE="$(ip -4 route show table "$DIRECT_UPSTREAM_TABLE" default 2>/dev/null)"
        fi
        DIRECT_UPSTREAM_IPV4="$(ip -4 -o addr show dev "$CELLULAR_IFACE" scope global 2>/dev/null | awk '{print $4}')"
        DIRECT_IPV6_PREFIX="$(cellular_ipv6_prefix)"
        DIRECT_HELPER_STATE="$(network_helper_state)"
        DIRECT_UPSTREAM_STATE="table=$DIRECT_UPSTREAM_TABLE rule=$DIRECT_UPSTREAM_RULE route=$DIRECT_UPSTREAM_ROUTE ipv4=$DIRECT_UPSTREAM_IPV4"
        DIRECT_IPV6_STATE="prefix=$DIRECT_IPV6_PREFIX helpers=$DIRECT_HELPER_STATE"
    }

    direct_br0_network_monitor() {
        DIRECT_UPSTREAM_LAST=""
        DIRECT_IPV6_LAST=""
        direct_full_sync_count="$DIRECT_BR0_FULL_SYNC_CYCLES"
        while is_running; do
            direct_br0_carrier_state
            if [ "$direct_full_sync_count" -ge "$DIRECT_BR0_FULL_SYNC_CYCLES" ]; then
                # br0 and the LAN are stable on this platform. Audit them only
                # periodically; the hot path watches carrier-owned state.
                sync_tether_network
                sync_ipv6_downstream
                sync_dhcp_block
                sync_upstream 1
                direct_full_sync_count=0
            else
                if [ "$DIRECT_UPSTREAM_STATE" != "$DIRECT_UPSTREAM_LAST" ]; then
                    # A cellular lease refresh may keep the same table name but
                    # rebuild Android's rules. Reinsert our ingress rule anyway.
                    sync_upstream 1
                fi
                if [ "$DIRECT_IPV6_STATE" != "$DIRECT_IPV6_LAST" ]; then
                    sync_ipv6_downstream
                fi
                direct_full_sync_count=$((direct_full_sync_count + 1))
            fi
            # Syncs can change the installed rule/helper state. Save the
            # post-repair snapshot so the next poll remains idle.
            direct_br0_carrier_state
            DIRECT_UPSTREAM_LAST="$DIRECT_UPSTREAM_STATE"
            DIRECT_IPV6_LAST="$DIRECT_IPV6_STATE"
            sleep "$DIRECT_BR0_MONITOR_POLL_SECONDS"
        done
    }

    network_state_fingerprint() {
        NET_STATE_TEXT="mode=$EFFECTIVE_TETHER_MODE bridge=$LAN_BRIDGE\n"
        for path in /sys/class/net/*; do
            iface="${path##*/}"
            iface_master="$(basename "$(readlink "$path/master" 2>/dev/null)" 2>/dev/null)"
            NET_STATE_TEXT="${NET_STATE_TEXT}iface=$iface master=${iface_master:-none}"
            if [ -d "$path/bridge" ]; then
                NET_STATE_TEXT="${NET_STATE_TEXT} bridge=1"
            else
                NET_STATE_TEXT="${NET_STATE_TEXT} bridge=0"
            fi
            NET_STATE_TEXT="${NET_STATE_TEXT}\n"
        done
        NET_STATE_TEXT="${NET_STATE_TEXT}tether=$TETHER_STATE\n"
        NET_STATE_TEXT="${NET_STATE_TEXT}prefix=$(cellular_ipv6_prefix)\n"
        NET_STATE_TEXT="${NET_STATE_TEXT}upstream=$(current_upstream_table)\n"
        NET_STATE_TEXT="${NET_STATE_TEXT}upstream_rule=$(ip -4 rule show priority "$UPSTREAM_RULE_PRIO" 2>/dev/null | awk '{print $NF; exit}')\n"
        NET_STATE_TEXT="${NET_STATE_TEXT}ipv4=$(ip -4 -o addr show 2>/dev/null | awk '{print $2 "=" $4}')\n"
        NET_STATE_TEXT="${NET_STATE_TEXT}$(network_helper_state)"
    }

    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        direct_br0_network_monitor
        return 0
    fi

    # Only run the expensive syncs when observable state changed. A periodic
    # full sync still repairs rules or helpers deleted outside this loop.
    NET_STATE_LAST=""
    sync_count=0
    while is_running; do
        TETHER_STATE="$(dumpsys tethering 2>/dev/null | grep ' - TetheredState')"
        TETHER_STATE_SET=1
        network_state_fingerprint
        if [ "$NET_STATE_TEXT" != "$NET_STATE_LAST" ] || [ "$sync_count" -ge "$MONITOR_FULL_SYNC_CYCLES" ]; then
            sync_tether_network
            sync_ipv6_downstream
            sync_dhcp_block
            # Guest WAN forwarding must follow Wi-Fi/cellular changes regardless
            # of whether Android's own locally generated traffic is taken over.
            sync_upstream
            network_state_fingerprint
            NET_STATE_LAST="$NET_STATE_TEXT"
            sync_count=0
        else
            sync_count=$((sync_count + 1))
        fi
        sleep "$MONITOR_POLL_SECONDS"
    done
}

start_monitor() {
    [ "${STANDALONE:-0}" = 1 ] && return 0
    [ "$NETWORK_MONITOR" = 1 ] || return 0
    if [ -r "$MONITOR_PIDFILE" ]; then
        monitor_pid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"
        [ -n "$monitor_pid" ] && [ -d "/proc/$monitor_pid" ] && return 0
    fi
    nohup "$0" __network_monitor </dev/null >/dev/null 2>&1 &
    echo "$!" > "$MONITOR_PIDFILE"
}

stop_monitor() {
    if [ -r "$MONITOR_PIDFILE" ]; then
        monitor_pid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"
        [ -n "$monitor_pid" ] && kill "$monitor_pid" 2>/dev/null || true
    fi
    rm -f "$MONITOR_PIDFILE"
    if [ -r "$WATCHDOG_PIDFILE" ]; then
        watchdog_pid="$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)"
        [ -n "$watchdog_pid" ] && kill "$watchdog_pid" 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_PIDFILE"
}

# Near-zero-cost guardian: polls /proc/<crosvm-pid> every 2 seconds.  If the
# guest powers itself off (or crosvm crashes) nobody stops the VM properly and
# the host networking stays in the "running" state, so we trigger the normal
# stop/teardown flow here.  Normal stops kill us via stop_monitor first.
vm_watchdog() {
    watched_pid="$1"
    echo "$$" > "$WATCHDOG_PIDFILE"
    trap 'rm -f "$WATCHDOG_PIDFILE"; exit 0' HUP TERM EXIT
    while [ -d "/proc/$watched_pid" ]; do
        sleep 10
    done
    # Only act if the plugin still expects this exact crosvm PID (i.e. nobody
    # ran stop_vm).  The stop path kills us through stop_monitor, so reaching
    # here means the guest died on its own.
    if [ -r "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$watched_pid" ]; then
        rm -f "$WATCHDOG_PIDFILE"
        trap - HUP TERM EXIT
        stop_vm
    fi
}

preflight_vm() {
    load_config
    resolve_device_config
    if [ "${STANDALONE:-0}" != 1 ] && [ "$UNSAFE_NATIVE_BRIDGE" = 1 ] && [ "$EFFECTIVE_TETHER_MODE" = bridge ]; then
        die "TETHER_MODE=bridge is unsafe on MU300/UMS9620 sprd_wlan_combo; use auto, proxyarp, or routed"
    fi
    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        [ -d "/sys/class/net/$NATIVE_TETHER_BRIDGE/bridge" ] || \
            die "TETHER_MODE=directbr0 requires native bridge $NATIVE_TETHER_BRIDGE"
        for member_path in "/sys/class/net/$NATIVE_TETHER_BRIDGE/brif"/ros-* \
                "/sys/class/net/$NATIVE_TETHER_BRIDGE/brif"/rosx-*; do
            [ -e "$member_path" ] || continue
            member="${member_path##*/}"
            [ "$member" = "$LAN_TAP" ] || \
                die "directbr0 refuses unexpected project port $member on $NATIVE_TETHER_BRIDGE"
        done
    fi
    [ "$(getprop ro.product.cpu.abi 2>/dev/null)" = arm64-v8a ] || \
        die "only arm64-v8a Android hosts are supported"
    [ -c /dev/kvm ] || die "/dev/kvm is unavailable"
    [ -c /dev/net/tun ] || die "/dev/net/tun is unavailable"
    if [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        [ -x "$DHCP_RELAY" ] || die "DHCP relay is missing or not executable: $DHCP_RELAY"
        [ -w /proc/sys/net/ipv4/conf/all/proxy_arp ] || die "kernel Proxy ARP controls are unavailable"
        # This branch's safety contract is stronger than merely avoiding the
        # old connector name: no project-created interface may ever be a port
        # of a vendor-owned tether bridge on the affected Wi-Fi driver.
        for bridge_path in /sys/class/net/*/bridge; do
            [ -e "$bridge_path" ] || continue
            bridge="${bridge_path%/bridge}"
            bridge="${bridge##*/}"
            is_tether_candidate "$bridge" || continue
            for member_path in "/sys/class/net/$bridge/brif"/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                case "$member" in
                    ros-*|rosx-*) die "unsafe project port $member is attached to native tether bridge $bridge" ;;
                esac
            done
        done
    fi
    for command in ip iptables ip6tables truncate stat dumpsys; do
        command -v "$command" >/dev/null 2>&1 || die "required Android command is missing: $command"
    done
    if [ -x "$KVM_PROBE" ]; then
        "$KVM_PROBE" >/dev/null || die "KVM/vGIC capability probe failed"
    fi

    probe_tap=ros-check0
    probe_bridge=ros-checkbr
    ip link delete "$probe_tap" 2>/dev/null || true
    ip link delete "$probe_bridge" type bridge 2>/dev/null || true
    if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ]; then
        if ! ip tuntap add dev "$probe_tap" mode tap multi_queue 2>/dev/null; then
            if [ "$VM_NET_QUEUES" = auto ]; then
                EFFECTIVE_NET_QUEUES=1
                ip tuntap add dev "$probe_tap" mode tap || \
                    die "kernel cannot create TAP interfaces"
            else
                die "kernel cannot create multiqueue TAP interfaces"
            fi
        fi
    else
        ip tuntap add dev "$probe_tap" mode tap || die "kernel cannot create TAP interfaces"
    fi
    ip link add name "$probe_bridge" type bridge || {
        ip link delete "$probe_tap" 2>/dev/null || true
        die "kernel cannot create Linux bridges"
    }
    ip link delete "$probe_tap" 2>/dev/null || true
    ip link delete "$probe_bridge" type bridge 2>/dev/null || true

    matched=""
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        matches_tether_pattern "$iface" && matched="$matched $iface"
    done
    [ "${STANDALONE:-0}" = 1 ] || [ -n "$matched" ] || \
        die "TETHER_IFACE_PATTERNS matches no current interface"
    echo "preflight ok: crosvm=$CROSVM style=$CROSVM_STYLE net_style=$CROSVM_NET_STYLE cpus=$VM_CPUS affinity=${EFFECTIVE_CPU_AFFINITY:-none} capacity=${EFFECTIVE_CPU_CAPACITY:-none} clusters=${EFFECTIVE_CPU_CLUSTERS:-none} net_queues=$EFFECTIVE_NET_QUEUES cellular=$CELLULAR_IFACE table=$CELLULAR_ROUTE_TABLE tether=${TETHER_IFACE_PATTERNS} mode=$EFFECTIVE_TETHER_MODE ipv6_passthrough=$IPV6_PASSTHROUGH"
}

start_vm() {
    load_config
    resolve_device_config
    preflight_vm >/dev/null
    # A previous crashed VM may have left Android drivers unbound and stale
    # state behind; hand those devices back before starting a fresh VM.
    usb_restore_all
    for file in "$DISK"; do
        [ -r "$file" ] || die "missing $file"
    done
    if is_running; then
        echo "RouterOS VM is already running (PID $(cat "$PIDFILE"))"
        exit 0
    fi
    rm -f "$PIDFILE" "$SOCKET"
    : > "$LOG"
    : > "$CONSOLE"
    setup_network
    cpu_affinity_arg=""
    [ -n "$EFFECTIVE_CPU_AFFINITY" ] && \
        cpu_affinity_arg="--cpu-affinity=$EFFECTIVE_CPU_AFFINITY"
    cpu_capacity_arg=""
    [ -n "$EFFECTIVE_CPU_CAPACITY" ] && \
        cpu_capacity_arg="--cpu-capacity=$EFFECTIVE_CPU_CAPACITY"
    cpu_cluster_args=""
    for cpu_cluster in $EFFECTIVE_CPU_CLUSTERS; do
        cpu_cluster_args="$cpu_cluster_args --cpu-cluster=$cpu_cluster"
    done
    if [ "$CROSVM_NET_STYLE" = "modern" ]; then
        net_args="--net tap-name=$WAN_TAP,vq-pairs=$EFFECTIVE_NET_QUEUES --net tap-name=$LAN_TAP,vq-pairs=$EFFECTIVE_NET_QUEUES"
    else
        net_queue_arg=""
        [ "$EFFECTIVE_NET_QUEUES" -gt 1 ] && \
            net_queue_arg="--net-vq-pairs=$EFFECTIVE_NET_QUEUES"
        net_args="$net_queue_arg --tap-name $WAN_TAP --tap-name $LAN_TAP"
    fi

    if [ "$CROSVM_STYLE" = block ]; then
        nohup "$CROSVM" run \
            --disable-sandbox \
            --cpus "$VM_CPUS" \
            $cpu_affinity_arg \
            $cpu_capacity_arg \
            $cpu_cluster_args \
            $net_args \
            $CROSVM_EXTRA_ARGS \
            --mem "$VM_MEMORY_MIB" \
            --socket "$SOCKET" \
            --serial "type=file,path=$CONSOLE,hardware=serial,num=1,console" \
            --block "path=$DISK,root=true" \
            </dev/null >>"$LOG" 2>&1 &
    else
        nohup "$CROSVM" run \
            --disable-sandbox \
            --cpus "$VM_CPUS" \
            $cpu_affinity_arg \
            $cpu_capacity_arg \
            $cpu_cluster_args \
            $net_args \
            $CROSVM_EXTRA_ARGS \
            --mem "$VM_MEMORY_MIB" \
            --socket "$SOCKET" \
            --serial "type=file,path=$CONSOLE,hardware=serial,num=1,console" \
            --rwdisk "$DISK" \
            </dev/null >>"$LOG" 2>&1 &
    fi
    vm_pid=$!
    echo "$vm_pid" > "$PIDFILE"
    sleep 2
    if ! is_running; then
        echo "crosvm exited during startup:" >&2
        tail -n 80 "$LOG" >&2
        rm -f "$PIDFILE"
        exit 1
    fi
    if [ "${STANDALONE:-0}" != 1 ] && [ "$AUTO_TAKEOVER" = 1 ]; then
        takeover
    else
        untakeover >/dev/null
    fi
    # Wait for the guest LAN to serve ARP/DHCP, then point clients' stale
    # ARP cache (still aimed at this host from the stopped transition) back
    # at the guest's MAC on the shared bridge.
    if ! wait_for_guest_lan; then
        echo "routeros: warning: guest LAN not ready within 30s" >&2
    fi
    announce_guest_mac
    start_monitor
    nohup "$0" __vm_watchdog "$vm_pid" </dev/null >/dev/null 2>&1 &
    echo "$!" > "$WATCHDOG_PIDFILE"
    usb_auto_attach
    echo "RouterOS VM started (PID $vm_pid, WAN $WAN_GUEST_IP, LAN $LAN_GUEST_IP, SSH host port $SSH_DNAT_PORT)"
}

stop_vm() {
    load_config
    resolve_device_config
    use_active_tether_mode
    stop_monitor
    if ! is_running; then
        rm -f "$PIDFILE" "$SOCKET"
        # A crashed or previously stopped VM may leave TAP devices, the LAN
        # bridge and DHCP-suppression rules behind.  Restore Android tethering
        # even when there is no crosvm process left to stop.
        teardown_network
        echo "RouterOS VM is not running"
        return 0
    fi
    pid="$(cat "$PIDFILE")"
    "$CROSVM" stop "$SOCKET" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    n=0
    while [ "$n" -lt 10 ] && [ -d "/proc/$pid" ]; do
        sleep 1
        n=$((n + 1))
    done
    if [ -d "/proc/$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$SOCKET"
    # Tear the bridge down only after crosvm has released its TAP devices.
    # This also restores Android hotspot/USB DHCP and their original addresses.
    teardown_network
    echo "RouterOS VM stopped"
}

status_vm() {
    load_config
    resolve_device_config
    use_active_tether_mode
    if is_running; then
        bridge_ports="$(ls "/sys/class/net/$LAN_BRIDGE/brif" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
        echo "running PID=$(cat "$PIDFILE") wan=$WAN_GUEST_IP lan=$LAN_GUEST_IP tether_mode=$EFFECTIVE_TETHER_MODE bridge=$LAN_BRIDGE ports=${bridge_ports:-none} net_queues=$EFFECTIVE_NET_QUEUES ipv6_passthrough=$IPV6_PASSTHROUGH standalone=${STANDALONE:-0} ssh=localhost:$SSH_DNAT_PORT"
    else
        echo "stopped"
        return 1
    fi
}

uninstall_vm() {
    stop_vm
    teardown_network
    [ "$VM_DIR" = /data/local/mikrotik ] || die "unsafe VM_DIR"
    rm -rf -- "$VM_DIR"
    echo "RouterOS VM data and networking rules removed"
}

# ---- USB passthrough (runtime, via crosvm usb) ----
# Attached state is kept in $VM_DIR/usb/<sysfs-name> (contains the crosvm
# port), and unbound Android drivers in <sysfs-name>.drv so detach / VM stop
# can hand the device back.  Attachments are runtime-only: they die with the
# crosvm process, so the state is cleared on start/stop.
USB_STATE_DIR="$VM_DIR/usb"
# Devices listed here (one "vid:pid" per line) are re-attached automatically
# after every VM start.  The list survives VM stop/restart; attachments don't.
AUTO_USB_FILE="$VM_DIR/usb-auto.conf"
# Set while sprd_networkcontrol is paused for a passed-through USB network
# adapter; the vendor watchdog is restarted on detach / VM stop.
USB_NETCTL_MARKER="$VM_DIR/usb-sprd-netctl-stopped"

usb_restore_drivers() {
    usb_name="$1"
    [ -r "$USB_STATE_DIR/$usb_name.drv" ] || return 0
    while read -r usb_intf usb_drv; do
        [ -n "$usb_intf" ] || continue
        if [ -d "/sys/bus/usb/drivers/$usb_drv" ]; then
            echo "$usb_intf" > "/sys/bus/usb/drivers/$usb_drv/bind" 2>/dev/null || true
        fi
    done < "$USB_STATE_DIR/$usb_name.drv"
    rm -f "$USB_STATE_DIR/$usb_name.drv"
}

usb_restore_all() {
    for state in "$USB_STATE_DIR"/*.drv; do
        [ -e "$state" ] || continue
        usb_name="${state##*/}"
        usb_name="${usb_name%.drv}"
        usb_restore_drivers "$usb_name"
    done
    rm -rf "$USB_STATE_DIR"
    # VM is stopping: every passed-through device is released, so the vendor
    # network watchdog can safely come back.
    if [ -f "$USB_NETCTL_MARKER" ]; then
        start sprd_networkcontrol 2>/dev/null || true
        rm -f "$USB_NETCTL_MARKER"
    fi
}

# Release one passed-through network adapter from the paused-vendor list.
# sprd_networkcontrol is only restarted when the LAST such adapter is gone,
# so detaching one of several USB NICs cannot let Android steal the others.
usb_release_vendor() {
    usb_rel_name="$1"
    if [ -f "$USB_NETCTL_MARKER" ]; then
        if [ -n "$usb_rel_name" ]; then
            grep -vxF "$usb_rel_name" "$USB_NETCTL_MARKER" > "$USB_NETCTL_MARKER.tmp" 2>/dev/null || true
            mv -f "$USB_NETCTL_MARKER.tmp" "$USB_NETCTL_MARKER" 2>/dev/null || true
        fi
        if [ ! -s "$USB_NETCTL_MARKER" ]; then
            start sprd_networkcontrol 2>/dev/null || true
            rm -f "$USB_NETCTL_MARKER"
        fi
    fi
}

usb_list() {
    if is_running; then
        echo "VM_RUNNING=1"
    else
        echo "VM_RUNNING=0"
    fi
    if [ -S "$SOCKET" ] && "$CROSVM" usb list "$SOCKET" >/dev/null 2>&1; then
        echo "USB_SUPPORT=1"
    else
        echo "USB_SUPPORT=0"
    fi
    if [ -r "$AUTO_USB_FILE" ]; then
        while read -r entry; do
            [ -n "$entry" ] || continue
            echo "AUTO|$entry"
        done < "$AUTO_USB_FILE"
    fi
    for path in /sys/bus/usb/devices/*; do
        [ -d "$path" ] || continue
        name="${path##*/}"
        case "$name" in usb[0-9]*) continue ;; esac
        bus="$(cat "$path/busnum" 2>/dev/null)"
        dev="$(cat "$path/devnum" 2>/dev/null)"
        vid="$(cat "$path/idVendor" 2>/dev/null)"
        pid="$(cat "$path/idProduct" 2>/dev/null)"
        [ -n "$bus" ] && [ -n "$dev" ] || continue
        manufacturer="$(cat "$path/manufacturer" 2>/dev/null)"
        product="$(cat "$path/product" 2>/dev/null)"
        claimed=""
        driver=""
        for intf in "$path"/[0-9]*-[0-9]*:[0-9]*.[0-9]*; do
            [ -e "$intf" ] || continue
            drv="$(basename "$(readlink "$intf/driver" 2>/dev/null)" 2>/dev/null)"
            if [ -n "$drv" ]; then
                claimed=1
                driver="${driver:+$driver,}$drv"
            fi
        done
        port=""
        if [ -r "$USB_STATE_DIR/$name" ]; then
            port="$(cat "$USB_STATE_DIR/$name" 2>/dev/null)"
        fi
        printf 'USB|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$name" "$bus" "$dev" "$vid" "$pid" \
            "$manufacturer" "$product" "${claimed:-0}" "${driver:-none}" "$port"
    done
}

usb_attach() {
    usb_name="$1"
    is_running || { echo "USB attach failed: VM is not running"; return 1; }
    usb_path="/sys/bus/usb/devices/$usb_name"
    [ -d "$usb_path" ] || { echo "USB attach failed: no such USB device: $usb_name"; return 1; }
    usb_bus="$(cat "$usb_path/busnum" 2>/dev/null)"
    usb_dev="$(cat "$usb_path/devnum" 2>/dev/null)"
    usb_vid="$(cat "$usb_path/idVendor" 2>/dev/null)"
    usb_pid="$(cat "$usb_path/idProduct" 2>/dev/null)"
    [ -n "$usb_bus" ] && [ -n "$usb_dev" ] && [ -n "$usb_vid" ] && [ -n "$usb_pid" ] || \
        { echo "USB attach failed: cannot read USB device ids for $usb_name"; return 1; }
    # usbfs device nodes use zero-padded bus/device numbers (e.g. 003/005).
    usb_devfile="/dev/bus/usb/$(printf '%03d' "$usb_bus")/$(printf '%03d' "$usb_dev")"
    [ -e "$usb_devfile" ] || usb_devfile="/dev/bus/usb/$usb_bus/$usb_dev"
    [ -e "$usb_devfile" ] || { echo "USB attach failed: missing USB device node $usb_devfile"; return 1; }
    if ! "$CROSVM" usb list "$SOCKET" >/dev/null 2>&1; then
        echo "USB attach failed: 当前 crosvm 未编译 USB 直通后端（缺少 xhci），无法直通"
        return 1
    fi
    # Force-release Android drivers first (crosvm requires a free device).
    mkdir -p "$USB_STATE_DIR"
    : > "$USB_STATE_DIR/$usb_name.drv"
    usb_is_net=0
    for usb_intf in "$usb_path"/[0-9]*-[0-9]*:[0-9]*.[0-9]*; do
        [ -e "$usb_intf" ] || continue
        usb_drv_link="$(readlink "$usb_intf/driver" 2>/dev/null)"
        [ -n "$usb_drv_link" ] || continue
        usb_drv="${usb_drv_link##*/}"
        case "$usb_drv" in ''|.) continue ;; esac
        [ -d "/sys/bus/usb/drivers/$usb_drv" ] || continue
        usb_intf_name="${usb_intf##*/}"
        echo "$usb_intf_name $usb_drv" >> "$USB_STATE_DIR/$usb_name.drv"
        case "$usb_drv" in
            r8152|ax88179_178a|ax88772b|asix|ax88172a|cdc_ether|rndis_host|cdc_ncm|rtl8150|aquantia|qmi_wwan|cdc_mbim)
                usb_is_net=1 ;;
        esac
    done
    # Unisoc firmware (sprd_networkcontrol/psimon) force-resets USB network
    # adapters until their driver re-binds, which snatches the device back
    # from the guest within seconds.  Pause the watchdog while the network
    # adapter is passed through; it is restarted on detach / VM stop.
    if [ "$usb_is_net" = 1 ]; then
        if getprop init.svc.sprd_networkcontrol 2>/dev/null | grep -qx running; then
            stop sprd_networkcontrol
        fi
        # touch (not truncate): several NICs may share this paused list.
        touch "$USB_NETCTL_MARKER"
    fi
    for usb_intf in "$usb_path"/[0-9]*-[0-9]*:[0-9]*.[0-9]*; do
        [ -e "$usb_intf" ] || continue
        usb_intf_name="${usb_intf##*/}"
        usb_drv_link="$(readlink "$usb_intf/driver" 2>/dev/null)"
        [ -n "$usb_drv_link" ] || continue
        usb_drv="${usb_drv_link##*/}"
        case "$usb_drv" in ''|.) continue ;; esac
        [ -d "/sys/bus/usb/drivers/$usb_drv" ] || continue
        echo "$usb_intf_name" > "/sys/bus/usb/drivers/$usb_drv/unbind" 2>/dev/null || true
    done
    usb_out="$("$CROSVM" usb attach "$usb_bus:$usb_dev:$usb_vid:$usb_pid" "$usb_devfile" "$SOCKET" 2>&1)"
    usb_rc=$?
    if [ "$usb_rc" = 0 ]; then
        usb_port="$(printf '%s\n' "$usb_out" | awk '/^ok[[:space:]]+[0-9]+/{print $2; exit}')"
        case "$usb_port" in
            ''|*[!0-9]*)
                # crosvm returned success without a usable numeric port
                # (typically a device that vanished mid-attach).  Never store
                # a placeholder port: detaching it would fail.
                usb_restore_drivers "$usb_name"
                usb_release_vendor "$usb_name"
                echo "USB attach failed: crosvm 未返回有效端口（原始输出：$usb_out）"
                return 1
                ;;
        esac
        # Attaching resets the device once, which can re-trigger the kernel
        # probe and re-bind the network driver.  Unbind again so the guest
        # keeps it; with the vendor watchdog paused nothing else re-claims it.
        usb_rebound=""
        for usb_try in 1 2 3; do
            usb_rebound=""
            for usb_intf in "$usb_path"/[0-9]*-[0-9]*:[0-9]*.[0-9]*; do
                [ -e "$usb_intf" ] || continue
                usb_drv_link="$(readlink "$usb_intf/driver" 2>/dev/null)"
                [ -n "$usb_drv_link" ] || continue
                usb_drv="${usb_drv_link##*/}"
                case "$usb_drv" in ''|.) continue ;; esac
                [ -d "/sys/bus/usb/drivers/$usb_drv" ] || continue
                usb_rebound=1
                echo "${usb_intf##*/}" > "/sys/bus/usb/drivers/$usb_drv/unbind" 2>/dev/null || true
            done
            [ -n "$usb_rebound" ] || break
            sleep 1
        done
        printf '%s\n' "$usb_port" > "$USB_STATE_DIR/$usb_name"
        if [ "$usb_is_net" = 1 ]; then
            printf '%s\n' "$usb_name" >> "$USB_NETCTL_MARKER"
        fi
        if [ -n "$usb_rebound" ]; then
            echo "USB device $usb_name attached to VM (port ${usb_port})，但驱动仍被宿主占用，建议取消直通后重试"
        else
            echo "USB device $usb_name attached to VM (port ${usb_port})"
        fi
    else
        usb_restore_drivers "$usb_name"
        usb_release_vendor "$usb_name"
        echo "USB attach failed: $usb_out"
        return 1
    fi
}

usb_detach() {
    usb_port="$1"
    is_running || { echo "USB detach failed: VM is not running"; return 1; }
    case "$usb_port" in
        ''|*[!0-9]*)
            # Invalid or stale port (e.g. the old "-" placeholder written by a
            # previous version after bad contact).  Clean up the state and hand
            # the device back to Android without calling crosvm.
            usb_name=""
            if [ -d "$USB_STATE_DIR" ]; then
                for state_file in "$USB_STATE_DIR"/*; do
                    [ -f "$state_file" ] || continue
                    case "${state_file##*/}" in *.drv) continue ;; esac
                    if [ "$(cat "$state_file" 2>/dev/null)" = "$usb_port" ]; then
                        usb_name="${state_file##*/}"
                        break
                    fi
                done
            fi
            if [ -n "$usb_name" ]; then
                usb_restore_drivers "$usb_name"
                rm -f "$USB_STATE_DIR/$usb_name"
                usb_release_vendor "$usb_name"
            fi
            echo "USB device detached from VM (port $usb_port)（无效端口，已清理状态并恢复宿主接管）"
            return 0
            ;;
    esac
    usb_name=""
    if [ -d "$USB_STATE_DIR" ]; then
        for state_file in "$USB_STATE_DIR"/*; do
            [ -f "$state_file" ] || continue
            case "${state_file##*/}" in *.drv) continue ;; esac
            if [ "$(cat "$state_file" 2>/dev/null)" = "$usb_port" ]; then
                usb_name="${state_file##*/}"
                break
            fi
        done
    fi
    usb_out="$("$CROSVM" usb detach "$usb_port" "$SOCKET" 2>&1)"
    usb_rc=$?
    if [ -n "$usb_name" ]; then
        usb_restore_drivers "$usb_name"
        rm -f "$USB_STATE_DIR/$usb_name"
        usb_release_vendor "$usb_name"
    fi
    if [ "$usb_rc" = 0 ]; then
        echo "USB device detached from VM (port $usb_port)"
    elif printf '%s\n' "$usb_out" | grep -qiE 'no_such_port|no such device|not attached'; then
        # The device already left the guest (bad contact); state is cleaned up.
        echo "USB device detached from VM (port $usb_port)（设备已不在虚拟机中，状态已清理）"
        return 0
    else
        echo "USB detach failed: $usb_out"
        return 1
    fi
}

usb_auto_add() {
    id="$1"
    case "$id" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) echo "auto passthrough add failed: invalid vid:pid: $id"; return 1 ;;
    esac
    id="$(printf '%s' "$id" | tr 'A-F' 'a-f')"
    touch "$AUTO_USB_FILE"
    if grep -qxF "$id" "$AUTO_USB_FILE" 2>/dev/null; then
        echo "auto passthrough already enabled for $id"
    else
        printf '%s\n' "$id" >> "$AUTO_USB_FILE"
        echo "auto passthrough enabled for $id"
    fi
}

usb_auto_del() {
    id="$1"
    [ -f "$AUTO_USB_FILE" ] || { echo "auto passthrough disabled for $id"; return 0; }
    if grep -qxF "$id" "$AUTO_USB_FILE" 2>/dev/null; then
        grep -vxF "$id" "$AUTO_USB_FILE" > "$AUTO_USB_FILE.tmp" 2>/dev/null
        mv -f "$AUTO_USB_FILE.tmp" "$AUTO_USB_FILE" 2>/dev/null || true
        echo "auto passthrough disabled for $id"
    else
        echo "auto passthrough disabled for $id"
        return 0
    fi
}

# Called after a fresh VM start: attach every device whose vid:pid is in the
# auto list.  Missing devices are skipped and will need a manual attach (or a
# later restart) once they are plugged in.
usb_auto_attach() {
    [ -r "$AUTO_USB_FILE" ] || return 0
    while read -r usb_id; do
        [ -n "$usb_id" ] || continue
        usb_name=""
        for usb_path in /sys/bus/usb/devices/*; do
            [ -d "$usb_path" ] || continue
            usb_sysname="${usb_path##*/}"
            case "$usb_sysname" in usb[0-9]*) continue ;; esac
            usb_v="$(cat "$usb_path/idVendor" 2>/dev/null)"
            usb_p="$(cat "$usb_path/idProduct" 2>/dev/null)"
            if [ "$usb_v:$usb_p" = "$usb_id" ]; then
                usb_name="$usb_sysname"
                break
            fi
        done
        [ -n "$usb_name" ] || continue
        usb_attach "$usb_name" || true
    done < "$AUTO_USB_FILE"
}

case "${1:-}" in
    __network_monitor) network_monitor ;;
    __vm_watchdog) vm_watchdog "$2" ;;
    start) start_vm ;;
    stop) stop_vm ;;
    restart) stop_vm; start_vm ;;
    status) status_vm ;;
    preflight) preflight_vm ;;
    crosvm-path)
        load_config
        resolve_crosvm_path
        printf '%s\n' "$CROSVM"
        ;;
    refresh-ipv6) refresh_ipv6 ;;
    logs) tail -n "${2:-200}" "$LOG" 2>/dev/null; echo "--- guest console ---"; tail -n "${2:-200}" "$CONSOLE" 2>/dev/null ;;
    usb)
        load_config
        case "${2:-}" in
            auto)
                case "${3:-}" in
                    add) usb_auto_add "$4" ;;
                    del) usb_auto_del "$4" ;;
                    *) echo "usage: $0 usb auto {add VID:PID|del VID:PID}" >&2; exit 2 ;;
                esac
                ;;
            list|attach|detach)
                resolve_device_config
                case "${2:-}" in
                    list) usb_list ;;
                    attach) usb_attach "$3" ;;
                    detach) usb_detach "$3" ;;
                esac
                ;;
            *) echo "usage: $0 usb {list|attach NAME|detach PORT|auto {add VID:PID|del VID:PID}}" >&2; exit 2 ;;
        esac
        ;;
    takeover) takeover ;;
    untakeover) untakeover ;;
    uninstall) uninstall_vm ;;
    *) echo "usage: $0 {start|stop|restart|status|preflight|crosvm-path|refresh-ipv6|logs [lines]|usb {list|attach NAME|detach PORT}|takeover|untakeover|uninstall}" >&2; exit 2 ;;
esac
