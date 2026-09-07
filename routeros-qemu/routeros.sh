#!/system/bin/sh
set -u

MANAGER_VERSION=2026090703

# RouterOS CHR (ARM64) runs under QEMU/KVM, not crosvm: CHR boots through UEFI
# (BOOTAA64.EFI in its ESP) and crosvm has no pflash/MMIO firmware path.  The
# Android networking layer below is unchanged from the crosvm build; only the
# VM launch, control channel and USB passthrough moved to QEMU.
VM_DIR=/data/local/mikrotik
BUNDLED_QEMU="$VM_DIR/qemu-system-aarch64"
BUNDLED_QEMU_ROOT="$VM_DIR/qemu"
QEMU=""
QEMU_LIB_DIR=""
QEMU_DATA_DIR=""
FIRMWARE=""
FIRMWARE_VARS="$VM_DIR/uefi-vars.fd"
FIRMWARE_VARS_TEMPLATE=""
DISK="$VM_DIR/routeros.img"
# Absolute path to this script, for the detached children that re-invoke it.
# "$0" is already absolute when launched from the boot script or the plug-in,
# but resolve it anyway so a relative invocation does not spawn a child that
# cannot find itself once nohup has changed nothing but the parent's lifetime.
case "$0" in
    /*) MANAGER_SELF="$0" ;;
    *)  MANAGER_SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac
[ -f "$MANAGER_SELF" ] || MANAGER_SELF="$VM_DIR/routeros.sh"
CONFIG="$VM_DIR/vm.conf"
FORWARDS="$VM_DIR/port-forwards.tsv"
PIDFILE="$VM_DIR/qemu.pid"
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
# Which of the two downstream IPv6 designs the host is currently wired for.
# Tracked separately from the prefix because the two modes hang fe80::1, the
# /64 route and the policy rules off different interfaces (ros-br vs ros-wan):
# switching between them while the carrier prefix happens to be unchanged has
# to still tear the old wiring down.
IPV6_MODE_FILE="$VM_DIR/ipv6-mode"
TAKEOVER_FLAG="$VM_DIR/takeover.enabled"
# QMP replaces the crosvm control socket: shutdown, USB hotplug and vCPU
# thread discovery all go through it.
SOCKET="$VM_DIR/qmp.sock"
SERIAL_SOCKET="$VM_DIR/serial.sock"
LOG="$VM_DIR/qemu.log"
CONSOLE="$VM_DIR/console.log"
TTYD="$VM_DIR/ttyd"
TTYD_PIDFILE="$VM_DIR/ttyd.pid"
TTYD_LOG="$VM_DIR/ttyd.log"
# Own directory rather than sharing DroidVM_UFI with the UEFI plug-in.
BACKUP_ROOT="${ROS_BACKUP_DIR:-/sdcard/RouterOS_QEMU}"
UPLOAD_ROOT="${ROS_UPLOAD_DIR:-/data/data/com.minikano.f50_sms/files/uploads}"
BACKUP_PROGRESS="$VM_DIR/backup-progress"
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
# 2224/8081 rather than OpenWrt's 2223/8080 so both plug-ins can coexist.
SSH_DNAT_PORT=2224
WEB_DNAT_PORT=8081
# WinBox is how RouterOS is normally managed, so it gets a built-in forward
# too.  8291 is WinBox's own port and is not used by the Android side.
WINBOX_DNAT_PORT=8291
ROUTED_IFACES_FILE="$VM_DIR/routed-tethers"
PROXYARP_IFACES_FILE="$VM_DIR/proxyarp-tethers"
DIRECT_BR0_ADDR_FILE="$VM_DIR/direct-br0.addr"
STOP_TRANSITION_DNS_FILE="$VM_DIR/stopped-transition-dns"
GARP="$VM_DIR/garp"
EFFECTIVE_TETHER_MODE=""
# QEMU has no --cpu-affinity/--cpu-capacity/--cpu-cluster.  EFFECTIVE_CPU_LIST
# is the ordered host CPU per vCPU (vCPU0 first); the whole process runs under
# taskset EFFECTIVE_CPU_MASK and each vCPU thread is pinned individually once
# QMP can report its thread id.
EFFECTIVE_CPU_LIST=""
EFFECTIVE_CPU_MASK=""
EFFECTIVE_NET_QUEUES=1
# vhost-net moves the virtio datapath into the kernel, but many Android
# kernels (this platform included) ship without CONFIG_VHOST_NET and have no
# loadable module, so it is probed rather than assumed.
EFFECTIVE_VHOST=off
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
    : "${QEMU_PATH:=auto}"
    : "${VM_VHOST:=auto}"
    : "${QEMU_EXTRA_ARGS:=}"
    : "${FIRMWARE_PATH:=auto}"
    : "${FIRMWARE_VARS_PATH:=auto}"
    : "${MACHINE:=virt}"
    : "${CPU_MODEL:=host}"
    : "${ACCEL:=kvm}"
    : "${RNG_ENABLED:=1}"
    : "${USB_BUS_ENABLED:=1}"
    : "${WAN_MAC:=52:54:00:6d:05:01}"
    : "${LAN_MAC:=52:54:00:6d:05:02}"
    : "${TTYD_ENABLED:=1}"
    # Must match the plug-in's DEFAULTS, or a vm.conf written by an older
    # build (missing the key) makes the UI show one bind address while the
    # backend uses another.  Non-loopback still refuses to start without
    # TTYD_CREDENTIAL, so this is not an open console by default.
    : "${TTYD_BIND:=0.0.0.0}"
    : "${TTYD_PORT:=7682}"
    : "${TTYD_CREDENTIAL:=}"
    # Credentials the offline maintenance console logs in with.  CHR ships as
    # admin with no password; once that is changed these must be updated or
    # maintenance (the LAN address sync) can no longer reach the CLI.
    : "${ROS_USER:=admin}"
    : "${ROS_PASSWORD:=}"
    # Guest-side NIC names.  QEMU enumerates the netdevs in command-line
    # order, so the WAN device is ether1 and the LAN device (the one that
    # carries LAN_GUEST_IP) is ether2.
    : "${ROS_WAN_IFACE:=wan}"
    : "${ROS_LAN_IFACE:=lan}"
    # Gateway mode moves DHCP off Android and onto RouterOS; without a server
    # in the guest, clients would simply get no lease.  Ignored when
    # STANDALONE=1 (Android keeps serving DHCP there).
    : "${BOOT_DELAY:=0}"
    : "${ROS_ULA_PREFIX:=}"
    : "${ROS_DHCP_ENABLED:=1}"
    : "${ROS_DHCP_POOL_START:=100}"
    : "${ROS_DHCP_POOL_END:=200}"
    : "${ROS_DHCP_LEASE:=1h}"
    case "$ROS_DHCP_ENABLED" in
        0|1) ;;
        *) die "ROS_DHCP_ENABLED must be 0 or 1" ;;
    esac
    for dhcp_octet in "$ROS_DHCP_POOL_START" "$ROS_DHCP_POOL_END"; do
        case "$dhcp_octet" in ''|*[!0-9]*) die "ROS_DHCP_POOL_START/END must be numbers" ;; esac
        [ "$dhcp_octet" -ge 2 ] && [ "$dhcp_octet" -le 254 ] || \
            die "ROS_DHCP_POOL_START/END must be between 2 and 254"
    done
    [ "$ROS_DHCP_POOL_START" -le "$ROS_DHCP_POOL_END" ] || \
        die "ROS_DHCP_POOL_START must not exceed ROS_DHCP_POOL_END"
    # A malformed lease-time would be rejected by RouterOS mid-script, and the
    # sync only verifies the address, so it would look like it succeeded.
    printf '%s\n' "$ROS_DHCP_LEASE" | grep -qE '^([0-9]+[smhdw])+$' || \
        die "ROS_DHCP_LEASE 格式无效（示例：30m、1h、1d）"
    # Nothing on the ros-wan link answers DNS, so the guest gets real
    # resolvers written into its own configuration.
    : "${ROS_DNS:=223.5.5.5,119.29.29.29}"
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
    case "$BOOT_DELAY" in
        ''|*[!0-9]*) die "BOOT_DELAY 必须是 0-900 之间的整数秒: $BOOT_DELAY" ;;
    esac
    [ "$BOOT_DELAY" -le 900 ] || die "BOOT_DELAY 最大 900 秒: $BOOT_DELAY"
    # Empty means "derive it" (see ros_ula_prefix).  A hand-set value has to be
    # three hex groups starting fd/fc -- RouterOS would reject anything else
    # mid-script, and sync only checks the IPv4 address afterwards, so a bad
    # value here would be reported as success.
    if [ -n "$ROS_ULA_PREFIX" ]; then
        printf '%s\n' "$ROS_ULA_PREFIX" | grep -qiE '^f[cd][0-9a-f]{2}(:[0-9a-f]{1,4}){2}$' || \
            die "ROS_ULA_PREFIX 必须形如 fdXX:XXXX:XXXX（三组十六进制，fc/fd 开头）: $ROS_ULA_PREFIX"
    fi
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
    case "$ACCEL" in
        kvm|tcg) ;;
        *) die "ACCEL must be kvm or tcg" ;;
    esac
    for flag_name in RNG_ENABLED USB_BUS_ENABLED TTYD_ENABLED; do
        eval "flag_value=\$$flag_name"
        case "$flag_value" in
            0|1) ;;
            *) die "$flag_name must be 0 or 1" ;;
        esac
    done
    for mac_name in WAN_MAC LAN_MAC; do
        eval "mac_value=\$$mac_name"
        printf '%s\n' "$mac_value" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || \
            die "$mac_name is not a MAC address: $mac_value"
    done
    [ "$WAN_MAC" != "$LAN_MAC" ] || die "WAN_MAC and LAN_MAC must differ"
    for port_name in SSH_DNAT_PORT WEB_DNAT_PORT WINBOX_DNAT_PORT TTYD_PORT; do
        eval "port_value=\$$port_name"
        case "$port_value" in
            ''|*[!0-9]*) die "$port_name must be a port number" ;;
        esac
        [ "$port_value" -ge 1 ] && [ "$port_value" -le 65535 ] || \
            die "$port_name is out of range: $port_value"
    done
    case "$MACHINE" in *[!A-Za-z0-9_.=,+-]*) die "MACHINE contains invalid characters" ;; esac
    case "$CPU_MODEL" in ''|*[!A-Za-z0-9_.+-]*) die "CPU_MODEL contains invalid characters" ;; esac
    case "$TTYD_CREDENTIAL" in
        '') ;;
        *:*) ;;
        *) die "TTYD_CREDENTIAL must use user:password form" ;;
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

# Expand "0,2-3" into "0 2 3".
expand_cpu_spec() {
    printf '%s\n' "${1:-}" | tr ',' '\n' | while read -r cpu_item; do
        [ -n "$cpu_item" ] || continue
        case "$cpu_item" in
            *-*)
                cpu_first="${cpu_item%-*}"
                cpu_last="${cpu_item#*-}"
                case "$cpu_first$cpu_last" in *[!0-9]*) return 1 ;; esac
                [ "$cpu_first" -le "$cpu_last" ] || return 1
                while [ "$cpu_first" -le "$cpu_last" ]; do
                    echo "$cpu_first"
                    cpu_first=$((cpu_first + 1))
                done
                ;;
            *[!0-9]*) return 1 ;;
            *) echo "$cpu_item" ;;
        esac
    done
}

# taskset on Android/toybox takes a hex mask, so build one from a CPU list.
# Bit arithmetic goes through a decimal accumulator because toybox awk has no
# or()/lshift().
cpu_list_to_mask() {
    printf '%s\n' $1 | sort -n -u | awk '
        BEGIN { for (i = 0; i < 64; i++) bit[i] = 0 }
        /^[0-9]+$/ { if ($1 < 64) bit[$1] = 1 }
        END {
            digits = "0123456789abcdef"
            out = ""
            any = 0
            for (nibble = 15; nibble >= 0; nibble--) {
                value = 0
                for (i = 3; i >= 0; i--) value = value * 2 + bit[nibble * 4 + i]
                if (value > 0) any = 1
                if (any) out = out substr(digits, value + 1, 1)
            }
            print out
        }
    '
}

# midr_el1 (or the "CPU part" line) identifies the microarchitecture.  With
# -cpu host every vCPU must land on the same one: QEMU reads the host ID once
# at init, so a vCPU thread that later runs on a different core fails with
# "Failed to put registers after init".
cpu_cluster_key() {
    cpu_key="$(cat "/sys/devices/system/cpu/cpu$1/regs/identification/midr_el1" 2>/dev/null)"
    if [ -z "$cpu_key" ]; then
        cpu_key="$(awk -v want="$1" '
            /^processor[[:space:]]*:/ {cpu=$3}
            /^CPU part[[:space:]]*:/ {if (cpu == want) {print $4; exit}}
        ' /proc/cpuinfo 2>/dev/null)"
    fi
    printf '%s\n' "${cpu_key:-unknown}"
}

cpu_score_of() {
    cpu_score="$(cat "/sys/devices/system/cpu/cpu$1/cpu_capacity" 2>/dev/null)"
    [ -n "$cpu_score" ] || cpu_score="$(cat "/sys/devices/system/cpu/cpu$1/cpufreq/cpuinfo_max_freq" 2>/dev/null)"
    case "$cpu_score" in *[!0-9]*|'') cpu_score=0 ;; esac
    printf '%s\n' "$cpu_score"
}

online_cpu_ids() {
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_id="${cpu_path##*cpu}"
        case "$cpu_id" in *[!0-9]*) continue ;; esac
        if [ -r "$cpu_path/online" ] && [ "$(cat "$cpu_path/online" 2>/dev/null)" != 1 ]; then
            continue
        fi
        echo "$cpu_id"
    done
}

# Pick the homogeneous cluster that can host VM_CPUS vCPUs; among those that
# can, prefer the fastest.  Falls back to the largest cluster (and clamps
# VM_CPUS to it) when no cluster is big enough.
select_homogeneous_cluster() {
    online_cpu_ids | while read -r cpu_id; do
        echo "$(cpu_cluster_key "$cpu_id") $(cpu_score_of "$cpu_id") $cpu_id"
    done | awk -v want="$VM_CPUS" '
        {
            key = $1
            count[key]++
            if ($2 > score[key]) score[key] = $2
            list[key] = (list[key] == "" ? $3 : list[key] " " $3)
        }
        END {
            best = ""
            for (key in count) {
                fits = (count[key] >= want)
                if (best == "") { best = key; bestfits = fits; continue }
                bf = bestfits
                # A cluster that fits always beats one that does not; between
                # two that fit (or two that do not) take the faster one, and
                # break ties on size.
                if (fits && !bf) { best = key; bestfits = fits; continue }
                if (fits == bf) {
                    if (score[key] > score[best] ||
                            (score[key] == score[best] && count[key] > count[best])) {
                        best = key; bestfits = fits
                    }
                }
            }
            if (best != "") print count[best] "\t" list[best]
        }
    '
}

resolve_cpu_affinity() {
    EFFECTIVE_CPU_LIST=""
    EFFECTIVE_CPU_MASK=""
    case "$VM_CPU_AFFINITY" in
        none)
            return 0
            ;;
        auto)
            cluster_row="$(select_homogeneous_cluster)"
            [ -n "$cluster_row" ] || die "cannot enumerate online Android CPUs"
            cluster_size="${cluster_row%%	*}"
            cluster_cpus="${cluster_row#*	}"
            if [ "$cluster_size" -lt "$VM_CPUS" ]; then
                echo "routeros: VM_CPUS=$VM_CPUS exceeds the largest homogeneous CPU cluster ($cluster_size); clamping to $cluster_size" >&2
                VM_CPUS="$cluster_size"
            fi
            EFFECTIVE_CPU_LIST="$(printf '%s\n' $cluster_cpus | head -n "$VM_CPUS" | tr '\n' ' ' | sed 's/ *$//')"
            ;;
        *[!0-9,-]*|'')
            die "invalid VM_CPU_AFFINITY: $VM_CPU_AFFINITY (use auto, none, or a CPU list like 6,7)"
            ;;
        *)
            expanded="$(expand_cpu_spec "$VM_CPU_AFFINITY")" || \
                die "invalid VM_CPU_AFFINITY: $VM_CPU_AFFINITY"
            [ -n "$expanded" ] || die "VM_CPU_AFFINITY selects no CPU"
            for cpu_id in $expanded; do
                [ -d "/sys/devices/system/cpu/cpu$cpu_id" ] || \
                    die "VM_CPU_AFFINITY references a CPU that does not exist: $cpu_id"
            done
            if [ "$CPU_MODEL" = host ] && [ "$ACCEL" = kvm ] && [ "${VM_CPU_ALLOW_HETERO:-0}" != 1 ]; then
                hetero_key=""
                for cpu_id in $expanded; do
                    this_key="$(cpu_cluster_key "$cpu_id")"
                    if [ -z "$hetero_key" ]; then
                        hetero_key="$this_key"
                    elif [ "$this_key" != "$hetero_key" ]; then
                        die "VM_CPU_AFFINITY spans different CPU microarchitectures ($hetero_key vs $this_key); -cpu host requires one cluster (set VM_CPU_ALLOW_HETERO=1 to override)"
                    fi
                done
            fi
            # One host CPU per vCPU, cycling if there are fewer CPUs than vCPUs.
            cpu_total=0
            for cpu_id in $expanded; do cpu_total=$((cpu_total + 1)); done
            cpu_index=0
            EFFECTIVE_CPU_LIST=""
            while [ "$cpu_index" -lt "$VM_CPUS" ]; do
                cpu_wanted=$((cpu_index % cpu_total))
                cpu_pos=0
                for cpu_id in $expanded; do
                    if [ "$cpu_pos" -eq "$cpu_wanted" ]; then
                        EFFECTIVE_CPU_LIST="$EFFECTIVE_CPU_LIST${EFFECTIVE_CPU_LIST:+ }$cpu_id"
                        break
                    fi
                    cpu_pos=$((cpu_pos + 1))
                done
                cpu_index=$((cpu_index + 1))
            done
            ;;
    esac
    if [ -n "$EFFECTIVE_CPU_LIST" ]; then
        EFFECTIVE_CPU_MASK="$(cpu_list_to_mask "$EFFECTIVE_CPU_LIST")"
        [ -n "$EFFECTIVE_CPU_MASK" ] || die "cannot build a taskset mask from CPU list: $EFFECTIVE_CPU_LIST"
    fi
}

# QEMU aborts with "open vhost char device failed" if vhost=on is requested
# and /dev/vhost-net is absent, so only ask for it when the node is really
# there.  VM_VHOST=auto (default) probes; on/off force the choice.
resolve_vhost() {
    case "${VM_VHOST:-auto}" in
        off) EFFECTIVE_VHOST=off ;;
        on)
            [ -c /dev/vhost-net ] || die "VM_VHOST=on but /dev/vhost-net does not exist (kernel has no vhost_net)"
            EFFECTIVE_VHOST=on
            ;;
        auto)
            if [ -c /dev/vhost-net ]; then
                EFFECTIVE_VHOST=on
            else
                EFFECTIVE_VHOST=off
            fi
            ;;
        *) die "VM_VHOST must be auto, on, or off" ;;
    esac
}

resolve_net_queues() {
    case "$VM_NET_QUEUES" in
        auto) EFFECTIVE_NET_QUEUES="$VM_CPUS" ;;
        *[!0-9]*|'') die "VM_NET_QUEUES must be auto or a positive integer" ;;
        0) die "VM_NET_QUEUES must be positive" ;;
        *)
            [ "$VM_NET_QUEUES" -le "$VM_CPUS" ] || \
                die "VM_NET_QUEUES cannot exceed VM_CPUS"
            EFFECTIVE_NET_QUEUES="$VM_NET_QUEUES"
            ;;
    esac
}

# The self-contained resource package ships QEMU under $VM_DIR/qemu; the
# DroidVM runtime is accepted as a fallback so both plug-ins can share one
# copy when they are installed side by side.
resolve_qemu_path() {
    QEMU=""
    case "$QEMU_PATH" in
        auto)
            for candidate in \
                    "$BUNDLED_QEMU_ROOT/usr/bin/qemu-system-aarch64" \
                    "$BUNDLED_QEMU" \
                    /data/local/droidvm/usr/bin/qemu-system-aarch64; do
                if [ -x "$candidate" ]; then
                    QEMU="$candidate"
                    break
                fi
            done
            [ -n "$QEMU" ] || die "qemu-system-aarch64 not found; reinstall the resource package"
            ;;
        bundled)
            if [ -x "$BUNDLED_QEMU_ROOT/usr/bin/qemu-system-aarch64" ]; then
                QEMU="$BUNDLED_QEMU_ROOT/usr/bin/qemu-system-aarch64"
            else
                QEMU="$BUNDLED_QEMU"
            fi
            ;;
        /*) QEMU="$QEMU_PATH" ;;
        *) die "QEMU_PATH must be auto, bundled, or an absolute device path" ;;
    esac
    [ -x "$QEMU" ] || die "qemu is not executable: $QEMU"
    # QEMU needs its shared libraries and its BIOS/keymap data directory; both
    # live next to the binary in the package layout <root>/usr/{bin,lib,share}.
    qemu_bin_dir="${QEMU%/*}"
    qemu_root="${qemu_bin_dir%/bin}"
    qemu_root="${qemu_root%/usr}"
    QEMU_LIB_DIR=""
    for candidate in "$qemu_root/usr/lib" "$qemu_bin_dir/../lib" "$VM_DIR/lib"; do
        [ -d "$candidate" ] || continue
        QEMU_LIB_DIR="$candidate"
        break
    done
    QEMU_DATA_DIR=""
    for candidate in "$qemu_root/usr/share/qemu" "$qemu_bin_dir/../share/qemu" "$VM_DIR/share/qemu"; do
        [ -d "$candidate" ] || continue
        QEMU_DATA_DIR="$candidate"
        break
    done
}

# CHR boots from its own ESP, so only the read-only code half of edk2 is
# needed; the writable half is a per-VM copy of the vars template.
resolve_firmware() {
    FIRMWARE=""
    case "$FIRMWARE_PATH" in
        auto)
            for candidate in \
                    "$VM_DIR/edk2-aarch64-code.fd" \
                    "$QEMU_DATA_DIR/edk2-aarch64-code.fd" \
                    /data/local/droidvm/usr/share/qemu/edk2-aarch64-code.fd; do
                [ -n "$candidate" ] || continue
                [ -r "$candidate" ] || continue
                FIRMWARE="$candidate"
                break
            done
            [ -n "$FIRMWARE" ] || die "UEFI firmware edk2-aarch64-code.fd not found; reinstall the resource package"
            ;;
        /*) FIRMWARE="$FIRMWARE_PATH" ;;
        *) die "FIRMWARE_PATH must be auto or an absolute device path" ;;
    esac
    [ -r "$FIRMWARE" ] || die "UEFI firmware is not readable: $FIRMWARE"

    FIRMWARE_VARS_TEMPLATE=""
    case "$FIRMWARE_VARS_PATH" in
        auto)
            for candidate in \
                    "$VM_DIR/edk2-arm-vars.fd" \
                    "$QEMU_DATA_DIR/edk2-arm-vars.fd" \
                    /data/local/droidvm/usr/share/qemu/edk2-arm-vars.fd; do
                [ -n "$candidate" ] || continue
                [ -r "$candidate" ] || continue
                FIRMWARE_VARS_TEMPLATE="$candidate"
                break
            done
            ;;
        /*) FIRMWARE_VARS_TEMPLATE="$FIRMWARE_VARS_PATH" ;;
        *) die "FIRMWARE_VARS_PATH must be auto or an absolute device path" ;;
    esac
}

# The writable pflash bank must exist and match the code bank's size before
# QEMU will map it.
ensure_firmware_vars() {
    [ -s "$FIRMWARE_VARS" ] && return 0
    if [ -n "$FIRMWARE_VARS_TEMPLATE" ] && [ -r "$FIRMWARE_VARS_TEMPLATE" ]; then
        cp "$FIRMWARE_VARS_TEMPLATE" "$FIRMWARE_VARS" || die "cannot create UEFI vars store"
    else
        firmware_size="$(stat -c%s "$FIRMWARE" 2>/dev/null)"
        case "$firmware_size" in ''|*[!0-9]*) firmware_size=67108864 ;; esac
        : > "$FIRMWARE_VARS" || die "cannot create UEFI vars store"
        truncate -s "$firmware_size" "$FIRMWARE_VARS" || die "cannot size UEFI vars store"
    fi
    chmod 600 "$FIRMWARE_VARS" 2>/dev/null || true
}

qemu_run() {
    if [ -n "$QEMU_LIB_DIR" ]; then
        LD_LIBRARY_PATH="$QEMU_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
    else
        "$@"
    fi
}

resolve_device_config() {
    resolve_qemu_path
    resolve_firmware
    resolve_cpu_affinity
    resolve_net_queues
    resolve_vhost

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
        # "usb*" matters on its own: some UFI kernels expose the RNDIS gadget as
        # a bare "usb0" rather than "sipa_usb0"/"rndis0".  is_tether_candidate
        # accepts it (auto mode trusts Android's TetheredState) and bridges it,
        # so leaving it out here let Android's dnsmasq keep answering DHCP on
        # the one downstream RouterOS was supposed to own.
        usb*|sipa_usb*|rndis*|wlan*|softap*|ap_br_wlan*|ap_br_softap*|bt-pan) return 0 ;;
    esac
    return 1
}

is_running() {
    [ -r "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$QEMU"
}

# ---- QMP control channel (replaces the crosvm control socket) ----
# QMP is line-delimited JSON: the server sends a greeting, then needs
# qmp_capabilities before it accepts anything else.  toybox nc -U is the only
# unix-socket client on the device, so commands are fed in one batch and the
# whole reply stream is returned for the caller to grep.
qmp_raw() {
    [ -S "$SOCKET" ] || return 1
    command -v nc >/dev/null 2>&1 || command -v toybox >/dev/null 2>&1 || return 1
    {
        printf '{"execute":"qmp_capabilities"}\n'
        while [ "$#" -gt 0 ]; do
            printf '%s\n' "$1"
            shift
        done
        # Give QEMU a moment to answer before nc tears the socket down.
        sleep 1
    } | toybox nc -U "$SOCKET" 2>/dev/null
}

# Returns 0 when QEMU acknowledged the last command with a "return" object.
qmp_cmd() {
    qmp_out="$(qmp_raw "$@")" || return 1
    printf '%s\n' "$qmp_out" | grep -q '"return"' || {
        qmp_error="$(printf '%s\n' "$qmp_out" | sed -n 's/.*"desc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
        [ -z "$qmp_error" ] || echo "$qmp_error" >&2
        return 1
    }
    return 0
}

json_escape() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
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

# Android's netd populates tetherctrl_counters with one rule pair per tethered
# downstream and empties the chain when tethering stops, so a non-empty chain
# means the device is still sharing its connection and needs ip_forward on.
tethering_active() {
    iptables -S tetherctrl_counters 2>/dev/null | grep -q '^-A '
}

rt_tables_file() {
    if [ -r /data/misc/net/rt_tables ]; then
        echo /data/misc/net/rt_tables
    else
        echo /etc/iproute2/rt_tables
    fi
}

# Flushing an address drops its connected route from *every* table it was in,
# including the per-network table Android's netd keeps (e.g. table 97 for the
# tether downstreams).  A later "ip addr add" only recreates the route in main,
# and Android's ip rules never consult main -- so the reply path for tethered
# clients falls through to "unreachable" and the hotspot silently dies.  Save
# the non-main/non-local routes here so bridge_detach can put them back.
save_iface_routes() {
    save_iface="$1"
    save_out="$2"
    save_rt="$(rt_tables_file)"
    : > "$save_out"
    ip -4 route show table all dev "$save_iface" 2>/dev/null | while read -r save_line; do
        case "$save_line" in
            *" table local "*|*" table local") continue ;;
            *" table "*) ;;
            *) continue ;;  # main: "ip addr add" recreates this one itself
        esac
        save_tname="$(printf '%s' "$save_line" | sed -n 's/.* table \([^ ]*\).*/\1/p')"
        [ -n "$save_tname" ] || continue
        case "$save_tname" in
            ''|*[!0-9]*)
                # rt_tables can map several names to one id (Android lists both
                # "local_network" and "wlan0" as 97) and name lookup is not
                # reliable in that case, so store the numeric id.
                save_tid="$(awk -v n="$save_tname" '$2 == n { id = $1 } END { print id }' \
                    "$save_rt" 2>/dev/null)" ;;
            *) save_tid="$save_tname" ;;
        esac
        [ -n "$save_tid" ] || continue
        save_spec="$(printf '%s' "$save_line" | sed "s/ table $save_tname//")"
        printf '%s|%s\n' "$save_tid" "$save_spec" >> "$save_out"
    done
}

# Reconstruct the per-network route when no save file exists -- either the
# interface was bridged by an older build, or the address was already flushed
# before we got to it.  Android keeps "oif <iface> ... lookup <table>" rules
# alive across the flush, so they still name the table the route belongs in.
rebuild_iface_routes() {
    rebuild_iface="$1"
    rebuild_cidr="$2"
    [ -n "$rebuild_cidr" ] || return 0
    rebuild_net="$(printf '%s\n' "$rebuild_cidr" | awk -F'[./]' \
        'NF >= 5 { print $1 "." $2 "." $3 ".0/" $5 }')"
    [ -n "$rebuild_net" ] || return 0
    ip -4 rule show 2>/dev/null | sed -n "s/.* oif $rebuild_iface .*lookup \([^ ]*\).*/\1/p" \
        | sort -u | while read -r rebuild_tname; do
        [ -n "$rebuild_tname" ] || continue
        case "$rebuild_tname" in
            ''|*[!0-9]*)
                rebuild_tid="$(awk -v n="$rebuild_tname" '$2 == n { id = $1 } END { print id }' \
                    "$(rt_tables_file)" 2>/dev/null)" ;;
            *) rebuild_tid="$rebuild_tname" ;;
        esac
        [ -n "$rebuild_tid" ] || continue
        ip -4 route replace "$rebuild_net" dev "$rebuild_iface" proto static scope link \
            table "$rebuild_tid" 2>/dev/null || true
    done
}

restore_iface_routes() {
    restore_iface="$1"
    restore_src="$2"
    restore_cidr="$3"
    if [ -s "$restore_src" ]; then
        while IFS='|' read -r restore_tid restore_spec; do
            [ -n "$restore_tid" ] && [ -n "$restore_spec" ] || continue
            # shellcheck disable=SC2086 -- the spec is a multi-token route body.
            ip -4 route replace $restore_spec dev "$restore_iface" table "$restore_tid" \
                2>/dev/null || true
        done < "$restore_src"
    else
        rebuild_iface_routes "$restore_iface" "$restore_cidr"
    fi
    rm -f "$restore_src"
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
            save_iface_routes "$iface" "$VM_DIR/bridge-$iface.routes"
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
        save_iface_routes "$iface" "$VM_DIR/bridge-$iface.routes"
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
        first_addr=""
        if [ -s "$VM_DIR/bridge-$iface.addr" ]; then
            while read -r saved_addr; do
                [ -n "$saved_addr" ] && ip -4 addr add "$saved_addr" dev "$iface" 2>/dev/null || true
            done < "$VM_DIR/bridge-$iface.addr"
            first_addr="$(head -n 1 "$VM_DIR/bridge-$iface.addr" 2>/dev/null)"
        fi
        restore_iface_routes "$iface" "$VM_DIR/bridge-$iface.routes" "$first_addr"
        rm -f "$VM_DIR/bridge-$iface.addr" "$VM_DIR/bridge-$iface.connector"
        return 0
    fi
    current_master="$(basename "$(readlink "/sys/class/net/$iface/master" 2>/dev/null)" 2>/dev/null)"
    [ "$current_master" = "$LAN_BRIDGE" ] || return 0
    ip link set dev "$iface" nomaster
    first_addr=""
    if [ -s "$VM_DIR/bridge-$iface.addr" ]; then
        while read -r saved_addr; do
            [ -n "$saved_addr" ] && ip -4 addr add "$saved_addr" dev "$iface" 2>/dev/null || true
        done < "$VM_DIR/bridge-$iface.addr"
        first_addr="$(head -n 1 "$VM_DIR/bridge-$iface.addr" 2>/dev/null)"
    fi
    restore_iface_routes "$iface" "$VM_DIR/bridge-$iface.routes" "$first_addr"
    rm -f "$VM_DIR/bridge-$iface.addr"
}

sync_bridge_ports() {
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        if is_tether_candidate "$iface"; then
            bridge_attach "$iface"
        elif [ -e "$VM_DIR/bridge-$iface.addr" ] || \
                [ -e "$VM_DIR/bridge-$iface.routes" ] || \
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

# The LAN prefix RouterOS advertises in managed mode.  It has to be a ULA, not
# a slice of the carrier prefix: mobile carriers hand out a single /64 with no
# prefix delegation, so there is nothing to subnet.  Deriving it from the guest
# LAN MAC rather than storing a random one keeps it stable across syncs and
# reinstalls while staying distinct per device -- which matters because
# sync_network_config can only reach RouterOS through an offline maintenance
# boot, so a LAN prefix that changed with the carrier's would mean rebooting
# the VM every time the cellular network renumbers.
ros_ula_prefix() {
    if [ -n "$ROS_ULA_PREFIX" ]; then
        printf '%s' "$ROS_ULA_PREFIX"
        return 0
    fi
    ula_hex="$(printf '%s' "$LAN_MAC" | sha256sum 2>/dev/null | cut -c1-10)"
    case "$ula_hex" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) ula_hex=00c0ffee01 ;;
    esac
    printf 'fd%s:%s:%s' \
        "$(printf '%s' "$ula_hex" | cut -c1-2)" \
        "$(printf '%s' "$ula_hex" | cut -c3-6)" \
        "$(printf '%s' "$ula_hex" | cut -c7-10)"
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

# ra6 hard-codes the lifetimes it advertises and takes no options for them.  The
# stock build says 45s, which Android 15+ drops outright (accept_ra_min_lft=180)
# -- phones then get no IPv6 at all while laptops are fine, which is a miserable
# thing to debug.  patch-ra6.py rewrites the three instructions holding those
# constants; report which build is installed so a stale helper is visible.
# Only the first 16 KiB is scanned: the sequence sits at ~0x7cc, well inside
# ra6's own code, and hashing the whole 540 KiB on every preflight is wasteful.
ra6_lifetime_state() {
    [ -x "$RA6" ] || { echo missing; return 0; }
    ra6_head="$(od -An -tx1 -v -N 16384 "$RA6" 2>/dev/null | tr -d ' \n')"
    case "$ra6_head" in
        *ea00a1728903e4f2c801a252*) echo patched ;;
        *0aa0a5720900eff208a0a552*) echo short ;;
        *) echo unknown ;;
    esac
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
    rm -f "$IPV6_PREFIX_FILE" "$IPV6_MODE_FILE"
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
    current_mode="$(cat "$IPV6_MODE_FILE" 2>/dev/null)"
    if [ "$current_prefix" != "$prefix" ] || [ "$current_mode" != passthrough ]; then
        stop_ipv6_downstream
        ip -6 addr replace fe80::1/64 dev "$LAN_BRIDGE"
        ip -6 route replace "$prefix/64" dev "$LAN_BRIDGE" metric 64 table main
        ip -6 rule add priority "$IPV6_OUT_RULE_PRIO" iif "$LAN_BRIDGE" lookup "$CELLULAR_ROUTE_TABLE"
        ip -6 rule add priority "$IPV6_IN_RULE_PRIO" iif "$CELLULAR_IFACE" to "$prefix/64" lookup main
        echo "$prefix" > "$IPV6_PREFIX_FILE"
        echo passthrough > "$IPV6_MODE_FILE"
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
    current_mode="$(cat "$IPV6_MODE_FILE" 2>/dev/null)"
    if [ "$current_prefix" != "$prefix" ] || [ "$current_mode" != managed ]; then
        stop_ipv6_downstream
        # RouterOS learns a public WAN address and default route from this RA.
        # Its own firewall performs NAT66 from the managed LAN ULA. Android
        # only routes that public WAN address to the cellular network.
        ip -6 addr replace fe80::1/64 dev "$WAN_TAP"
        ip -6 route replace "$prefix/64" dev "$WAN_TAP" metric 64 table main
        ip -6 rule add priority "$IPV6_OUT_RULE_PRIO" iif "$WAN_TAP" lookup "$CELLULAR_ROUTE_TABLE"
        ip -6 rule add priority "$IPV6_IN_RULE_PRIO" iif "$CELLULAR_IFACE" to "$prefix/64" lookup main
        echo "$prefix" > "$IPV6_PREFIX_FILE"
        echo managed > "$IPV6_MODE_FILE"
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
        for iface_prefix in usb+ sipa_usb+ rndis+ wlan+ softap+ ap_br_wlan+ ap_br_softap+; do
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

    # LAN_HOST_IP defaults to the UFI's own lan_ipaddr, which a native tether
    # interface (usb0/br0) usually already owns with the same /24.  Two
    # interfaces in one subnet make the guest's address ambiguous and the
    # kernel picks the native one, so host-originated traffic and the
    # SSH/Webfig/port-forward DNAT targets never reach the VM.  A host route
    # pins the guest to the interface it is actually on.
    ip route replace "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE"

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
    # The rule above only covers sources OUTSIDE the LAN subnet.  In
    # standalone mode LAN_HOST_IP is the UFI's own tether address, so tether
    # clients sit INSIDE that subnet and are excluded -- RouterOS then answers
    # a forwarded connection directly to a client that is not on its segment,
    # ARPs for it on the guest bridge, and the reply is lost.  Match on the
    # connection having been DNATed instead: that is exactly the port-forward
    # return path, and it leaves genuine same-segment traffic (gateway mode,
    # where RouterOS must see real client addresses) untouched.
    iptables -t nat -A ROS_POST -o "$LAN_BRIDGE" -m conntrack --ctstate DNAT \
        -j SNAT --to-source "$LAN_HOST_IP" 2>/dev/null || \
        echo "routeros: warning: conntrack match unavailable; 端口转发可能无法回包" >&2
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
    iptables -t nat -A ROS_PRE -p tcp --dport "$WINBOX_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:8291"
    ensure_jump nat PREROUTING ROS_PRE
    apply_forwards

    # Android owns AP/RNDIS lifecycle. Bridge mode moves DHCP/RA to RouterOS;
    # Routed fallback retains Android DHCP. Proxy-ARP and bridge modes suppress
    # Android DHCP so RouterOS is the only server clients can hear.
    sync_dhcp_block

}

teardown_network() {
    untakeover
    # USB attachments die with the qemu process; unbind any drivers we
    # took from Android and hand the devices back to the host.
    usb_restore_all
    stop_ipv6_downstream
    ip rule del priority "$UPSTREAM_RULE_PRIO" 2>/dev/null || true
    detach_bridge_ports
    ip route flush table "$ROS_TABLE" 2>/dev/null || true
    ip route del "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE" 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    delete_jump_and_chain filter FORWARD ROS_FWD
    delete_jump_and_chain nat POSTROUTING ROS_POST
    delete_jump_and_chain nat PREROUTING ROS_PRE
    delete_jump_and_chain nat PREROUTING ROS_UPRE
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
        saved_forward="$(cat "$VM_DIR/ip_forward.original" 2>/dev/null)"
        # ip_forward is global and shared with Android's own tethering.  The
        # snapshot is taken once at setup, so it goes stale the moment the user
        # toggles the hotspot -- restoring a stale 0 then kills tethering for
        # everything, with no VM left to explain why.  Only ever lower it when
        # nothing else is currently forwarding.
        if [ "$saved_forward" = 0 ] && tethering_active; then
            saved_forward=1
        fi
        case "$saved_forward" in
            0|1)
                printf '%s\n' "$saved_forward" > /proc/sys/net/ipv4/ip_forward 2>/dev/null || \
                    sysctl -w "net.ipv4.ip_forward=$saved_forward" >/dev/null 2>&1 || true ;;
        esac
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

# Near-zero-cost guardian: polls /proc/<qemu-pid> every 2 seconds.  If the
# guest powers itself off (or qemu crashes) nobody stops the VM properly and
# the host networking stays in the "running" state, so we trigger the normal
# stop/teardown flow here.  Normal stops kill us via stop_monitor first.
vm_watchdog() {
    watched_pid="$1"
    echo "$$" > "$WATCHDOG_PIDFILE"
    trap 'rm -f "$WATCHDOG_PIDFILE"; exit 0' HUP TERM EXIT
    while [ -d "/proc/$watched_pid" ]; do
        sleep 10
    done
    # Only act if the plugin still expects this exact qemu PID (i.e. nobody
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

    # QEMU must actually be runnable (shared libraries resolve) and must have
    # the backends this design depends on.
    qemu_version="$(qemu_run "$QEMU" --version 2>&1 | head -n 1)"
    case "$qemu_version" in
        *"QEMU emulator version"*) ;;
        *) die "cannot execute qemu: $qemu_version" ;;
    esac
    qemu_run "$QEMU" -M "$MACHINE" -netdev help 2>&1 | grep -qx tap || \
        die "this qemu build has no tap netdev backend"
    if [ "$USB_BUS_ENABLED" = 1 ]; then
        qemu_run "$QEMU" -device help 2>&1 | grep -q '"usb-host"' || \
            echo "routeros: warning: this qemu build has no usb-host device; USB passthrough will be unavailable" >&2
    fi
    [ -r "$FIRMWARE" ] || die "UEFI firmware is missing: $FIRMWARE"
    validate_forwards
    echo "preflight ok: qemu=$QEMU firmware=$FIRMWARE accel=$ACCEL cpus=$VM_CPUS cpu_list=${EFFECTIVE_CPU_LIST:-none} mask=${EFFECTIVE_CPU_MASK:-none} net_queues=$EFFECTIVE_NET_QUEUES vhost=$EFFECTIVE_VHOST cellular=$CELLULAR_IFACE table=$CELLULAR_ROUTE_TABLE tether=${TETHER_IFACE_PATTERNS} mode=$EFFECTIVE_TETHER_MODE ipv6_passthrough=$IPV6_PASSTHROUGH ra6=$(ra6_lifetime_state)"
}

# crosvm pinned each vCPU with --cpu-affinity; QEMU has no equivalent, so ask
# QMP for the vCPU thread ids and taskset them one by one.  Without this the
# scheduler is free to migrate a vCPU across the cluster boundary, which on a
# heterogeneous SoC breaks -cpu host.
pin_vcpu_threads() {
    [ -n "$EFFECTIVE_CPU_LIST" ] || return 0
    vcpu_threads=""
    pin_try=0
    while [ "$pin_try" -lt 10 ]; do
        vcpu_threads="$(qmp_raw '{"execute":"query-cpus-fast"}' 2>/dev/null \
            | tr ',' '\n' \
            | sed -n 's/.*"thread-id"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p')"
        [ -n "$vcpu_threads" ] && break
        sleep 1
        pin_try=$((pin_try + 1))
    done
    if [ -z "$vcpu_threads" ]; then
        echo "routeros: warning: QMP did not report vCPU threads; leaving them on the process mask" >&2
        return 0
    fi
    pin_index=0
    for vcpu_tid in $vcpu_threads; do
        pin_pos=0
        for pin_cpu in $EFFECTIVE_CPU_LIST; do
            if [ "$pin_pos" -eq "$pin_index" ]; then
                taskset -p "$(cpu_list_to_mask "$pin_cpu")" "$vcpu_tid" >/dev/null 2>&1 || true
                break
            fi
            pin_pos=$((pin_pos + 1))
        done
        pin_index=$((pin_index + 1))
    done
}

is_ttyd_running() {
    [ -r "$TTYD_PIDFILE" ] || return 1
    ttyd_pid="$(cat "$TTYD_PIDFILE" 2>/dev/null)"
    [ -n "$ttyd_pid" ] || return 1
    [ -d "/proc/$ttyd_pid" ] || return 1
    tr '\000' ' ' < "/proc/$ttyd_pid/cmdline" 2>/dev/null | grep -q ttyd
}

# Web serial console.  RouterOS is configured remotely, so this exists for
# first-run setup and recovery only and binds to loopback by default.
start_ttyd() {
    [ "$TTYD_ENABLED" = 1 ] || return 0
    [ -x "$TTYD" ] || return 0
    is_ttyd_running && return 0
    # A console bound anywhere but loopback is reachable by every client on the
    # hotspot, and this one is a root shell into the router.  Refuse rather
    # than quietly exposing it.
    case "$TTYD_BIND" in
        127.0.0.1|localhost|::1) ;;
        *)
            if [ -z "$TTYD_CREDENTIAL" ]; then
                echo "routeros: refusing to start ttyd on $TTYD_BIND without TTYD_CREDENTIAL (set 用户名:密码)" >&2
                return 1
            fi
            ;;
    esac
    ttyd_credential_arg=""
    [ -n "$TTYD_CREDENTIAL" ] && ttyd_credential_arg="-c $TTYD_CREDENTIAL"
    : > "$TTYD_LOG"
    nohup "$TTYD" -i "$TTYD_BIND" -p "$TTYD_PORT" $ttyd_credential_arg --writable \
        toybox nc -U "$SERIAL_SOCKET" </dev/null >>"$TTYD_LOG" 2>&1 &
    echo "$!" > "$TTYD_PIDFILE"
    sleep 1
    is_ttyd_running || {
        echo "routeros: warning: ttyd failed to start; see $TTYD_LOG" >&2
        rm -f "$TTYD_PIDFILE"
    }
}

stop_ttyd() {
    if [ -r "$TTYD_PIDFILE" ]; then
        ttyd_pid="$(cat "$TTYD_PIDFILE" 2>/dev/null)"
        [ -n "$ttyd_pid" ] && kill "$ttyd_pid" 2>/dev/null || true
    fi
    rm -f "$TTYD_PIDFILE"
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
    rm -f "$PIDFILE" "$SOCKET" "$SERIAL_SOCKET"
    : > "$LOG"
    : > "$CONSOLE"
    ensure_firmware_vars
    setup_network

    # Two virtio NICs on the TAPs the network layer just created: ether1 is
    # WAN, ether2 is LAN.  vhost keeps the datapath in the kernel; multiqueue
    # needs the vectors budget raised to 2*queues+2.
    # setup_network may have downgraded the queue count if the kernel refused
    # a multiqueue TAP, so read EFFECTIVE_NET_QUEUES only after it has run.
    # The queue count here must match how the TAP was created: opening a
    # multi_queue TAP single-queue (or vice versa) fails with
    # "could not configure /dev/net/tun: Invalid argument".
    net_args=""
    if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ]; then
        net_vectors=$((EFFECTIVE_NET_QUEUES * 2 + 2))
        net_args="-netdev tap,id=wan0,ifname=$WAN_TAP,script=no,downscript=no,vhost=$EFFECTIVE_VHOST,queues=$EFFECTIVE_NET_QUEUES"
        net_args="$net_args -device virtio-net-pci,netdev=wan0,mac=$WAN_MAC,mq=on,vectors=$net_vectors,disable-legacy=on,disable-modern=off"
        net_args="$net_args -netdev tap,id=lan0,ifname=$LAN_TAP,script=no,downscript=no,vhost=$EFFECTIVE_VHOST,queues=$EFFECTIVE_NET_QUEUES"
        net_args="$net_args -device virtio-net-pci,netdev=lan0,mac=$LAN_MAC,mq=on,vectors=$net_vectors,disable-legacy=on,disable-modern=off"
    else
        net_args="-netdev tap,id=wan0,ifname=$WAN_TAP,script=no,downscript=no,vhost=$EFFECTIVE_VHOST"
        net_args="$net_args -device virtio-net-pci,netdev=wan0,mac=$WAN_MAC,disable-legacy=on,disable-modern=off"
        net_args="$net_args -netdev tap,id=lan0,ifname=$LAN_TAP,script=no,downscript=no,vhost=$EFFECTIVE_VHOST"
        net_args="$net_args -device virtio-net-pci,netdev=lan0,mac=$LAN_MAC,disable-legacy=on,disable-modern=off"
    fi

    extra_device_args=""
    [ "$RNG_ENABLED" = 1 ] && extra_device_args="$extra_device_args -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0,disable-legacy=on,disable-modern=off"
    # An xhci controller has to exist up front or USB hotplug has no bus to
    # attach to; RouterOS itself needs no input devices.
    [ "$USB_BUS_ENABLED" = 1 ] && extra_device_args="$extra_device_args -device qemu-xhci,id=usb-bus"

    accel_args="-accel $ACCEL"
    [ "$ACCEL" = tcg ] && accel_args="-accel tcg,thread=multi"

    taskset_cmd=""
    [ -n "$EFFECTIVE_CPU_MASK" ] && taskset_cmd="taskset $EFFECTIVE_CPU_MASK"

    # The console is a socket so ttyd and the maintenance CLI can attach to a
    # live console, with logfile= keeping the plain-text log the UI tails.
    nohup $taskset_cmd env ${QEMU_LIB_DIR:+LD_LIBRARY_PATH="$QEMU_LIB_DIR"} \
        "$QEMU" \
        -name "routeros-vm" \
        ${QEMU_DATA_DIR:+-L "$QEMU_DATA_DIR"} \
        $accel_args \
        -machine "$MACHINE" \
        -cpu "$CPU_MODEL" \
        -smp "$VM_CPUS" \
        -m "${VM_MEMORY_MIB}M" \
        -nodefaults \
        -no-reboot \
        -rtc base=utc \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$FIRMWARE" \
        -drive "if=pflash,format=raw,unit=1,file=$FIRMWARE_VARS" \
        -drive "file=$DISK,if=none,id=osdisk,format=raw,cache=writeback,aio=threads,discard=unmap" \
        -device "virtio-blk-pci,drive=osdisk,disable-legacy=on,disable-modern=off,bootindex=1" \
        -chardev "socket,id=uart0,path=$SERIAL_SOCKET,server=on,wait=off,logfile=$CONSOLE,logappend=on" \
        -serial chardev:uart0 \
        -qmp "unix:$SOCKET,server=on,wait=off" \
        -display none \
        -vga none \
        $net_args \
        $extra_device_args \
        $QEMU_EXTRA_ARGS \
        </dev/null >>"$LOG" 2>&1 &
    vm_pid=$!
    echo "$vm_pid" > "$PIDFILE"
    sleep 2
    if ! is_running; then
        echo "qemu exited during startup:" >&2
        tail -n 80 "$LOG" >&2
        rm -f "$PIDFILE" "$SOCKET" "$SERIAL_SOCKET"
        # setup_network already created the taps, the bridge, the policy
        # routing rules and the iptables chains.  Leaving them behind after a
        # failed launch strands the host network in a half-configured state.
        stop_ttyd
        teardown_network
        exit 1
    fi
    pin_vcpu_threads
    start_ttyd
    # AUTO_TAKEOVER forces it on at every start; otherwise TAKEOVER_FLAG
    # remembers whatever the last manual `takeover`/`untakeover` chose, so a
    # restart does not silently drop it.  (The flag used to be written and
    # never read — this is what it was for.)
    if [ "${STANDALONE:-0}" != 1 ] && \
            { [ "$AUTO_TAKEOVER" = 1 ] || [ -f "$TAKEOVER_FLAG" ]; }; then
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
    echo "RouterOS VM started (PID $vm_pid, WAN $WAN_GUEST_IP, LAN $LAN_GUEST_IP, SSH $SSH_DNAT_PORT, Webfig $WEB_DNAT_PORT, WinBox $WINBOX_DNAT_PORT)"
}

stop_vm() {
    load_config
    resolve_device_config
    use_active_tether_mode
    stop_monitor
    stop_ttyd
    if ! is_running; then
        rm -f "$PIDFILE" "$SOCKET" "$SERIAL_SOCKET"
        # A crashed or previously stopped VM may leave TAP devices, the LAN
        # bridge and DHCP-suppression rules behind.  Restore Android tethering
        # even when there is no qemu process left to stop.
        teardown_network
        echo "RouterOS VM is not running"
        return 0
    fi
    pid="$(cat "$PIDFILE")"
    # ACPI powerdown lets RouterOS flush its configuration to disk; RouterOS
    # honours it, so give it a real chance before escalating.
    qmp_cmd '{"execute":"system_powerdown"}' >/dev/null 2>&1 || true
    n=0
    while [ "$n" -lt 20 ] && [ -d "/proc/$pid" ]; do
        sleep 1
        n=$((n + 1))
    done
    if [ -d "/proc/$pid" ]; then
        qmp_cmd '{"execute":"quit"}' >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
        n=0
        while [ "$n" -lt 10 ] && [ -d "/proc/$pid" ]; do
            sleep 1
            n=$((n + 1))
        done
    fi
    if [ -d "/proc/$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$SOCKET" "$SERIAL_SOCKET"
    # Tear the bridge down only after qemu has released its TAP devices.
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
        ttyd_state=stopped
        is_ttyd_running && ttyd_state="$TTYD_BIND:$TTYD_PORT"
        takeover_state=off
        [ -f "$TAKEOVER_FLAG" ] && takeover_state=on
        echo "running PID=$(cat "$PIDFILE") wan=$WAN_GUEST_IP lan=$LAN_GUEST_IP tether_mode=$EFFECTIVE_TETHER_MODE bridge=$LAN_BRIDGE ports=${bridge_ports:-none} net_queues=$EFFECTIVE_NET_QUEUES ipv6_passthrough=$IPV6_PASSTHROUGH standalone=${STANDALONE:-0} ssh=localhost:$SSH_DNAT_PORT web=localhost:$WEB_DNAT_PORT winbox=localhost:$WINBOX_DNAT_PORT cpu_list=${EFFECTIVE_CPU_LIST:-none} ttyd=$ttyd_state takeover=$takeover_state"
    else
        echo "stopped"
        return 1
    fi
}

uninstall_vm() {
    stop_vm
    stop_ttyd
    teardown_network
    [ "$VM_DIR" = /data/local/mikrotik ] || die "unsafe VM_DIR"
    rm -rf -- "$VM_DIR"
    echo "RouterOS VM data and networking rules removed"
}

# ---- USB passthrough (runtime, via QMP usb-host hotplug) ----
# Attached state is kept in $VM_DIR/usb/<sysfs-name> (contains the allocated
# port), and unbound Android drivers in <sysfs-name>.drv so detach / VM stop
# can hand the device back.  Attachments are runtime-only: they die with the
# qemu process, so the state is cleared on start/stop.
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
    # Passthrough needs three things: an xhci bus in the guest, a qemu built
    # with usb-host, and a reachable QMP socket to hotplug through.
    if [ "$USB_BUS_ENABLED" = 1 ] \
            && qemu_run "$QEMU" -device help 2>&1 | grep -q '"usb-host"' \
            && [ -S "$SOCKET" ] \
            && qmp_cmd '{"execute":"query-status"}' >/dev/null 2>&1; then
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
    if [ "$USB_BUS_ENABLED" != 1 ]; then
        echo "USB attach failed: USB_BUS_ENABLED=0，虚拟机没有 xhci 控制器，无法直通"
        return 1
    fi
    if ! qemu_run "$QEMU" -device help 2>&1 | grep -q '"usb-host"'; then
        echo "USB attach failed: 当前 qemu 未编译 usb-host 后端，无法直通"
        return 1
    fi
    if ! qmp_cmd '{"execute":"query-status"}' >/dev/null 2>&1; then
        echo "USB attach failed: 无法连接 QMP（$SOCKET）"
        return 1
    fi
    # Force-release Android drivers first (usb-host requires a free device).
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
    # crosvm allocated the "port" itself; with QMP we own the id, so keep a
    # monotonic counter and derive the QMP device id from it.  The UI contract
    # (a numeric port passed back to "usb detach") is unchanged.
    mkdir -p "$USB_STATE_DIR"
    usb_port="$(cat "$USB_STATE_DIR/.next-port" 2>/dev/null)"
    case "$usb_port" in ''|*[!0-9]*) usb_port=1 ;; esac
    echo "$((usb_port + 1))" > "$USB_STATE_DIR/.next-port"
    usb_qmp_id="usbdev$usb_port"
    usb_out="$(qmp_raw "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-host\",\"id\":\"$usb_qmp_id\",\"bus\":\"usb-bus.0\",\"hostbus\":$usb_bus,\"hostaddr\":$usb_dev}}" 2>&1)"
    if printf '%s\n' "$usb_out" | grep -q '"error"'; then
        usb_rc=1
        usb_out="$(printf '%s\n' "$usb_out" | sed -n 's/.*"desc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
        [ -n "$usb_out" ] || usb_out="QMP device_add 失败"
    else
        usb_rc=0
    fi
    if [ "$usb_rc" = 0 ]; then
        printf '%s\n' "$usb_qmp_id" > "$USB_STATE_DIR/$usb_name.qmp"
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
            # the device back to Android without calling QMP.
            usb_name=""
            if [ -d "$USB_STATE_DIR" ]; then
                for state_file in "$USB_STATE_DIR"/*; do
                    [ -f "$state_file" ] || continue
                    case "${state_file##*/}" in *.drv|*.qmp) continue ;; esac
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
            case "${state_file##*/}" in *.drv|*.qmp) continue ;; esac
            if [ "$(cat "$state_file" 2>/dev/null)" = "$usb_port" ]; then
                usb_name="${state_file##*/}"
                break
            fi
        done
    fi
    usb_qmp_id=""
    [ -n "$usb_name" ] && usb_qmp_id="$(cat "$USB_STATE_DIR/$usb_name.qmp" 2>/dev/null)"
    [ -n "$usb_qmp_id" ] || usb_qmp_id="usbdev$usb_port"
    usb_out="$(qmp_raw "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"$usb_qmp_id\"}}" 2>&1)"
    if printf '%s\n' "$usb_out" | grep -q '"error"'; then
        usb_rc=1
        usb_out="$(printf '%s\n' "$usb_out" | sed -n 's/.*"desc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
        [ -n "$usb_out" ] || usb_out="QMP device_del 失败"
    else
        usb_rc=0
    fi
    if [ -n "$usb_name" ]; then
        usb_restore_drivers "$usb_name"
        rm -f "$USB_STATE_DIR/$usb_name" "$USB_STATE_DIR/$usb_name.qmp"
        usb_release_vendor "$usb_name"
    fi
    if [ "$usb_rc" = 0 ]; then
        echo "USB device detached from VM (port $usb_port)"
    elif printf '%s\n' "$usb_out" | grep -qiE 'no_such_port|no such device|not attached|not found|Device .* not found'; then
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

# ---- User port forwards ----
# QEMU's hostfwd only exists on the user-mode netdev, and this VM is on TAPs,
# so forwards are iptables DNAT into the guest's LAN address.  They live in
# their own chain so they can be re-applied without touching the fixed
# SSH/Webfig rules in ROS_PRE.
# Format (TSV): enabled<TAB>name<TAB>proto<TAB>bind<TAB>hostport<TAB>guestport
validate_forwards() {
    [ -r "$FORWARDS" ] || return 0
    fwd_seen=''
    while IFS="$(printf '\t')" read -r fwd_on fwd_name fwd_proto fwd_bind fwd_host fwd_guest fwd_extra; do
        [ -n "${fwd_on}${fwd_name}${fwd_proto}${fwd_bind}${fwd_host}${fwd_guest}${fwd_extra}" ] || continue
        [ -z "${fwd_extra:-}" ] || die "端口映射 $fwd_name 字段过多"
        [ "$fwd_on" = 0 ] || [ "$fwd_on" = 1 ] || die "端口映射 $fwd_name 的启用值无效"
        case "$fwd_name" in ''|*[!A-Za-z0-9_.-]*) die '端口映射名称只能包含字母、数字、点、横线和下划线' ;; esac
        case "$fwd_proto" in tcp|udp) ;; *) die "端口映射 $fwd_name 的协议无效" ;; esac
        case "$fwd_bind" in
            0.0.0.0|'') ;;
            *) printf '%s\n' "$fwd_bind" | awk -F. 'NF != 4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1}' >/dev/null 2>&1 || \
                die "端口映射 $fwd_name 的绑定地址无效" ;;
        esac
        for fwd_port in "$fwd_host" "$fwd_guest"; do
            case "$fwd_port" in ''|*[!0-9]*) die "端口映射 $fwd_name 的端口无效" ;; esac
            [ "$fwd_port" -ge 1 ] && [ "$fwd_port" -le 65535 ] || die "端口映射 $fwd_name 的端口超出范围"
        done
        [ "$fwd_on" = 1 ] || continue
        case ";$fwd_seen" in
            *";$fwd_proto|$fwd_host;"*) die "端口映射冲突: $fwd_proto/$fwd_host" ;;
        esac
        fwd_seen="$fwd_seen$fwd_proto|$fwd_host;"
        for fwd_reserved in "$SSH_DNAT_PORT" "$WEB_DNAT_PORT" "$WINBOX_DNAT_PORT" "$TTYD_PORT"; do
            [ "$fwd_proto" = tcp ] && [ "$fwd_host" = "$fwd_reserved" ] && \
                die "端口映射 $fwd_name 与插件保留端口 $fwd_reserved 冲突"
        done
    done < "$FORWARDS"
}

apply_forwards() {
    iptables -t nat -N ROS_UPRE 2>/dev/null || true
    iptables -t nat -F ROS_UPRE
    if [ -r "$FORWARDS" ]; then
        # Traffic already inside the VM's own taps must not be re-DNATed.
        iptables -t nat -A ROS_UPRE -i "$WAN_TAP" -j RETURN
        iptables -t nat -A ROS_UPRE -i "$LAN_TAP" -j RETURN
        while IFS="$(printf '\t')" read -r fwd_on fwd_name fwd_proto fwd_bind fwd_host fwd_guest fwd_extra; do
            [ "${fwd_on:-0}" = 1 ] || continue
            fwd_dst_arg=""
            case "${fwd_bind:-0.0.0.0}" in
                0.0.0.0|'') ;;
                *) fwd_dst_arg="-d $fwd_bind" ;;
            esac
            iptables -t nat -A ROS_UPRE -p "$fwd_proto" $fwd_dst_arg --dport "$fwd_host" \
                -j DNAT --to-destination "$LAN_GUEST_IP:$fwd_guest" 2>/dev/null || \
                echo "routeros: warning: 端口映射 $fwd_name 应用失败" >&2
        done < "$FORWARDS"
    fi
    ensure_jump nat PREROUTING ROS_UPRE
}

list_forwards() {
    load_config
    [ -r "$FORWARDS" ] || return 0
    while IFS="$(printf '\t')" read -r fwd_on fwd_name fwd_proto fwd_bind fwd_host fwd_guest fwd_extra; do
        [ -n "${fwd_name:-}" ] || continue
        printf 'FWD|%s|%s|%s|%s|%s|%s\n' \
            "$fwd_on" "$fwd_name" "$fwd_proto" "${fwd_bind:-0.0.0.0}" "$fwd_host" "$fwd_guest"
    done < "$FORWARDS"
}

# ---- Disk maintenance ----
disk_bytes() {
    stat -c%s "$DISK" 2>/dev/null || toybox stat -c%s "$DISK" 2>/dev/null || wc -c < "$DISK"
}

disk_allocated_bytes() {
    disk_blocks="$(stat -c%b "$DISK" 2>/dev/null || toybox stat -c%b "$DISK" 2>/dev/null)"
    case "$disk_blocks" in
        ''|*[!0-9]*) disk_bytes ;;
        *) echo $((disk_blocks * 512)) ;;
    esac
}

show_disk_info() {
    load_config
    [ -r "$DISK" ] || die "missing $DISK"
    echo "DISK_PATH=$DISK"
    echo "DISK_BYTES=$(disk_bytes)"
    echo "DISK_ALLOCATED=$(disk_allocated_bytes)"
    if is_running; then echo "DISK_RUNNING=1"; else echo "DISK_RUNNING=0"; fi
}

# RouterOS extends its own partition on boot, so growing the raw file is
# enough; shrinking is refused because it would truncate live data.
resize_disk() {
    load_config
    resize_gib="${1:-}"
    resize_mode="${2:-expand}"
    case "$resize_gib" in ''|*[!0-9]*) die "disk-resize 需要 GiB 整数" ;; esac
    [ "$resize_gib" -ge 1 ] || die "磁盘容量至少 1 GiB"
    [ "$resize_mode" = expand ] || die "仅支持 expand（收缩会截断数据）"
    is_running && die "请先停止虚拟机再调整磁盘"
    resize_target=$((resize_gib * 1024 * 1024 * 1024))
    resize_current="$(disk_bytes)"
    [ "$resize_target" -gt "$resize_current" ] || \
        die "目标容量 ${resize_gib}GiB 不大于当前容量（$resize_current 字节）"
    truncate -s "$resize_target" "$DISK" || die "扩容失败"
    echo "磁盘已扩容到 ${resize_gib} GiB，RouterOS 启动后会自动扩展分区"
}

# Punch holes back into the sparse file so freed guest blocks stop occupying
# Android storage.
reclaim_disk() {
    load_config
    is_running && die "请先停止虚拟机再回收空间"
    [ -r "$DISK" ] || die "missing $DISK"
    reclaim_before="$(disk_allocated_bytes)"
    if command -v fstrim >/dev/null 2>&1 && fstrim -v "$DISK" >/dev/null 2>&1; then
        :
    else
        # No discard support for a plain file: rewrite it sparsely instead.
        reclaim_tmp="$DISK.reclaim"
        rm -f "$reclaim_tmp"
        if cp --sparse=always "$DISK" "$reclaim_tmp" 2>/dev/null; then
            mv "$reclaim_tmp" "$DISK" || { rm -f "$reclaim_tmp"; die "回收失败"; }
        else
            rm -f "$reclaim_tmp"
            echo "当前环境不支持稀疏回收，已跳过"
            return 0
        fi
    fi
    reclaim_after="$(disk_allocated_bytes)"
    echo "已回收：$reclaim_before -> $reclaim_after 字节"
}

# ---- Backup / restore ----
# restore/delete take a path from the UI, and both are destructive, so the
# path must be a DIRECT child of BACKUP_ROOT.  Checking only the prefix and a
# character whitelist is not enough: "." and "/" are legal characters, so
# "$BACKUP_ROOT/../something" passes a naive check and escapes the directory.
backup_path_valid() {
    backup_candidate="${1:-}"
    case "$backup_candidate" in
        "$BACKUP_ROOT"/*) ;;
        *) return 1 ;;
    esac
    backup_leaf="${backup_candidate#"$BACKUP_ROOT"/}"
    # Exactly one path segment, no traversal, no empty name.
    case "$backup_leaf" in
        ''|.|..) return 1 ;;
        */*) return 1 ;;
        *[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

backup_vm() {
    load_config
    backup_name="${1:-}"
    case "$backup_name" in ''|*[!A-Za-z0-9_.-]*) die "备份名称只能包含字母、数字、点、横线和下划线" ;; esac
    is_running && die "请先停止虚拟机再备份"
    [ -r "$DISK" ] || die "missing $DISK"
    backup_dir="$BACKUP_ROOT/$backup_name"
    mkdir -p "$backup_dir" || die "无法创建备份目录: $backup_dir"
    : > "$BACKUP_PROGRESS"
    cp "$CONFIG" "$backup_dir/vm.conf" 2>/dev/null || true
    [ -r "$FORWARDS" ] && cp "$FORWARDS" "$backup_dir/port-forwards.tsv" 2>/dev/null || true
    if command -v gzip >/dev/null 2>&1; then
        gzip -c "$DISK" > "$backup_dir/routeros.img.gz" || die "备份失败"
        printf '%s\n' routeros.img.gz > "$backup_dir/.payload"
    else
        cp "$DISK" "$backup_dir/routeros.img" || die "备份失败"
        printf '%s\n' routeros.img > "$backup_dir/.payload"
    fi
    rm -f "$BACKUP_PROGRESS"
    echo "备份完成: $backup_dir"
}

list_backups() {
    [ -d "$BACKUP_ROOT" ] || return 0
    for backup_dir in "$BACKUP_ROOT"/*; do
        [ -d "$backup_dir" ] || continue
        backup_payload="$(cat "$backup_dir/.payload" 2>/dev/null)"
        [ -n "$backup_payload" ] || continue
        backup_size="$(stat -c%s "$backup_dir/$backup_payload" 2>/dev/null || echo 0)"
        printf 'BACKUP|%s|%s|%s\n' "${backup_dir##*/}" "$backup_dir" "$backup_size"
    done
}

restore_backup() {
    load_config
    backup_dir="${1:-}"
    backup_path_valid "$backup_dir" || die "非法备份路径: $backup_dir"
    [ -d "$backup_dir" ] || die "备份不存在: $backup_dir"
    backup_payload="$(cat "$backup_dir/.payload" 2>/dev/null)"
    [ -n "$backup_payload" ] || die "备份缺少 .payload 标记"
    [ -r "$backup_dir/$backup_payload" ] || die "备份数据缺失: $backup_payload"
    is_running && die "请先停止虚拟机再恢复"
    # Restore through a temporary file so an interrupted copy cannot leave a
    # half-written disk in place of a working one.
    restore_tmp="$DISK.restore"
    rm -f "$restore_tmp"
    case "$backup_payload" in
        *.gz) gzip -dc "$backup_dir/$backup_payload" > "$restore_tmp" || { rm -f "$restore_tmp"; die "解压失败"; } ;;
        *) cp "$backup_dir/$backup_payload" "$restore_tmp" || { rm -f "$restore_tmp"; die "复制失败"; } ;;
    esac
    mv "$restore_tmp" "$DISK" || { rm -f "$restore_tmp"; die "恢复失败"; }
    # A restored disk belongs to a different UEFI variable store; drop the old
    # one so the firmware re-enumerates the boot entry.
    rm -f "$FIRMWARE_VARS"
    echo "已恢复: $backup_dir"
}

delete_backup() {
    backup_dir="${1:-}"
    backup_path_valid "$backup_dir" || die "非法备份路径: $backup_dir"
    [ -d "$backup_dir" ] || die "备份不存在: $backup_dir"
    rm -rf -- "$backup_dir"
    echo "已删除: $backup_dir"
}

# ---- Guest console ----
# Base64 in, so the caller never has to quote RouterOS CLI syntax through the
# Android shell.
console_write() {
    load_config
    console_payload="${1:-}"
    is_running || die '虚拟机未运行'
    [ -S "$SERIAL_SOCKET" ] || die 'UART socket 尚未就绪'
    printf '%s' "$console_payload" | base64 -d 2>/dev/null | toybox nc -q 1 -U "$SERIAL_SOCKET" >/dev/null 2>&1 || \
        die '写入 UART 失败'
    echo 'UART 输入已发送'
}

# Poll a growing console log until $1 (an ERE) shows up, or give up.
maint_wait_for() {
    maint_pattern="$1"
    maint_file="$2"
    maint_limit="$3"
    maint_elapsed=0
    while [ "$maint_elapsed" -lt "$maint_limit" ]; do
        if grep -aqE "$maint_pattern" "$maint_file" 2>/dev/null; then
            return 0
        fi
        sleep 2
        maint_elapsed=$((maint_elapsed + 2))
    done
    return 1
}

# ---- Offline maintenance boot ----
# Boots the disk headless with a scripted serial session (used to write the
# LAN address into RouterOS), then lets the guest shut itself down.  The
# caller supplies the input script and gets the console log.
maint_run() {
    load_config
    resolve_qemu_path
    resolve_firmware
    maint_in="${1:-}"
    maint_log="${2:-}"
    [ -n "$maint_in" ] && [ -r "$maint_in" ] || die "maint 需要可读的输入脚本"
    [ -n "$maint_log" ] || die "maint 需要日志路径"
    is_running && die "维护模式要求虚拟机已停止"
    [ -r "$DISK" ] || die "missing $DISK"
    maint_vars="$VM_DIR/uefi-vars.maint.fd"
    rm -f "$maint_vars"
    if [ -n "$FIRMWARE_VARS_TEMPLATE" ] && [ -r "$FIRMWARE_VARS_TEMPLATE" ]; then
        cp "$FIRMWARE_VARS_TEMPLATE" "$maint_vars"
    elif [ -s "$FIRMWARE_VARS" ]; then
        cp "$FIRMWARE_VARS" "$maint_vars"
    else
        maint_size="$(stat -c%s "$FIRMWARE" 2>/dev/null)"
        case "$maint_size" in ''|*[!0-9]*) maint_size=67108864 ;; esac
        : > "$maint_vars"
        truncate -s "$maint_size" "$maint_vars"
    fi
    : > "$maint_log"
    maint_mask=""
    [ -n "$EFFECTIVE_CPU_MASK" ] || resolve_cpu_affinity
    [ -n "$EFFECTIVE_CPU_MASK" ] && maint_mask="taskset $EFFECTIVE_CPU_MASK"
    maint_sock="$VM_DIR/maint-serial.sock"
    maint_err="$VM_DIR/maint-stderr.log"
    rm -f "$maint_sock"
    : > "$maint_err"
    # Launched without timeout(1) on purpose: timeout's PID is not qemu's, so
    # killing it would leave the VM running and holding the image's write
    # lock.  taskset and env both exec, so $! really is the qemu process.
    # A file chardev is output-only, so the console is a socket: QEMU logs
    # everything to $maint_log via logfile= while a feeder writes the CLI
    # script in once the guest has had time to reach its login prompt.
    # The NICs must be present and in the same order as the real VM, or
    # RouterOS has no ether1/ether2 to assign an address to.  Each one hangs
    # off its own empty hub: the guest sees a link, nothing else is on the
    # segment, and unlike a user netdev there is no built-in DHCP server
    # handing out a stray dynamic lease.  Maintenance therefore still cannot
    # touch host tethering.
    $maint_mask env ${QEMU_LIB_DIR:+LD_LIBRARY_PATH="$QEMU_LIB_DIR"} \
        "$QEMU" \
        -name routeros-maint \
        ${QEMU_DATA_DIR:+-L "$QEMU_DATA_DIR"} \
        -accel "$ACCEL" \
        -machine "$MACHINE" \
        -cpu "$CPU_MODEL" \
        -smp 1 \
        -m 512M \
        -nodefaults \
        -no-reboot \
        -rtc base=utc \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$FIRMWARE" \
        -drive "if=pflash,format=raw,unit=1,file=$maint_vars" \
        -drive "file=$DISK,if=none,id=osdisk,format=raw,cache=writeback,aio=threads" \
        -device "virtio-blk-pci,drive=osdisk,disable-legacy=on,disable-modern=off,bootindex=1" \
        -chardev "socket,id=uart0,path=$maint_sock,server=on,wait=off,logfile=$maint_log,logappend=on" \
        -serial chardev:uart0 \
        -display none \
        -vga none \
        -netdev hubport,id=m0,hubid=90 \
        -device "virtio-net-pci,netdev=m0,mac=$WAN_MAC,disable-legacy=on,disable-modern=off" \
        -netdev hubport,id=m1,hubid=91 \
        -device "virtio-net-pci,netdev=m1,mac=$LAN_MAC,disable-legacy=on,disable-modern=off" \
        </dev/null >>"$maint_err" 2>&1 &
    maint_pid=$!

    maint_wait=0
    while [ "$maint_wait" -lt 30 ] && [ ! -S "$maint_sock" ] && [ -d "/proc/$maint_pid" ]; do
        sleep 1
        maint_wait=$((maint_wait + 1))
    done
    # QEMU creates the chardev socket before it opens the disk, so the socket
    # existing is not proof of a healthy VM: a leaked VM still holding the
    # image's write lock gets this far and then exits.  Require actual console
    # output, otherwise report qemu's stderr instead of a bogus login failure.
    maint_boot_wait=0
    while [ "$maint_boot_wait" -lt 20 ] && [ -d "/proc/$maint_pid" ] && [ ! -s "$maint_log" ]; do
        sleep 1
        maint_boot_wait=$((maint_boot_wait + 1))
    done
    if [ ! -d "/proc/$maint_pid" ] || [ ! -s "$maint_log" ]; then
        [ -d "/proc/$maint_pid" ] && kill -9 "$maint_pid" 2>/dev/null || true
        rm -f "$maint_vars" "$maint_sock"
        maint_reason="$(grep -v '^$' "$maint_err" 2>/dev/null | head -n 3 | tr '\n' ' ')"
        case "$maint_reason" in
            *'Failed to get "write" lock'*)
                die "维护模式启动失败：磁盘被占用，可能有残留的 qemu 进程仍在运行（$DISK）"
                ;;
        esac
        die "维护模式 qemu 启动失败：${maint_reason:-未知错误（见 $maint_err）}"
    fi
    if [ -S "$maint_sock" ]; then
        # One persistent connection through a FIFO.  Feeding the whole script
        # in a single burst does not work: RouterOS's getty reads the login
        # and password prompts one line at a time and silently discards
        # anything that arrives before each prompt is ready, so every line is
        # paced and the console log is polled for the expected prompt.
        maint_fifo="$VM_DIR/maint-uart.in"
        rm -f "$maint_fifo"
        mkfifo "$maint_fifo" 2>/dev/null || die "无法创建维护 FIFO"
        toybox nc -U "$maint_sock" >/dev/null 2>&1 < "$maint_fifo" &
        maint_nc_pid=$!
        exec 9> "$maint_fifo"

        maint_wait_for 'CHR Login:|Login:' "$maint_log" "${MAINT_BOOT_TIMEOUT:-120}" || \
            echo "routeros: warning: 未等到登录提示符，继续尝试" >&2
        printf '%s\n' "$ROS_USER" >&9
        maint_wait_for 'Password:' "$maint_log" 20 || true
        printf '%s\n' "$ROS_PASSWORD" >&9
        # The prompt is "[user@identity] >" once the session is up.
        if maint_wait_for "\\[$ROS_USER@" "$maint_log" 40; then
            while IFS= read -r maint_line; do
                printf '%s\n' "$maint_line" >&9
                sleep "${MAINT_LINE_DELAY:-3}"
            done < "$maint_in"
            sleep "${MAINT_TAIL_DELAY:-15}"
        else
            echo "routeros: warning: 登录失败（检查 vm.conf 的 ROS_USER / ROS_PASSWORD）" >&2
        fi

        exec 9>&-
        rm -f "$maint_fifo"
        [ -d "/proc/$maint_nc_pid" ] && kill "$maint_nc_pid" 2>/dev/null || true
    else
        echo "routeros: warning: 维护串口 socket 未就绪" >&2
    fi

    # The script ends with /system shutdown, so wait for a clean exit before
    # forcing it.  Escalate all the way to SIGKILL: a survivor would keep the
    # image's write lock and break the next maintenance run.
    maint_wait=0
    while [ "$maint_wait" -lt 90 ] && [ -d "/proc/$maint_pid" ]; do
        sleep 1
        maint_wait=$((maint_wait + 1))
    done
    if [ -d "/proc/$maint_pid" ]; then
        kill "$maint_pid" 2>/dev/null || true
        maint_wait=0
        while [ "$maint_wait" -lt 10 ] && [ -d "/proc/$maint_pid" ]; do
            sleep 1
            maint_wait=$((maint_wait + 1))
        done
        [ -d "/proc/$maint_pid" ] && kill -9 "$maint_pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$maint_vars" "$maint_sock"
    if [ -s "$maint_err" ]; then
        echo "__MAINT_STDERR__=$maint_err"
    fi
    echo "__MAINT_DONE__"
}

# Write LAN_GUEST_IP into the RouterOS configuration on disk.  The CLI details
# live here rather than in the plug-in: the interactive "/system shutdown"
# confirmation and the ether1/ether2 mapping are properties of this backend.
# Build a RouterOS "ranges=" string covering [start,end] of the LAN /24 with
# the host and guest addresses punched out, so the pool can never hand a
# client an address that is already taken.  Emits up to three sub-ranges.
dhcp_pool_ranges() {
    awk -v net="$1" -v first="$2" -v last="$3" -v a="$4" -v b="$5" '
        BEGIN {
            n = 0
            if (a >= first && a <= last) excl[n++] = a
            if (b >= first && b <= last && b != a) excl[n++] = b
            # insertion sort; at most two entries
            if (n == 2 && excl[0] > excl[1]) { tmp = excl[0]; excl[0] = excl[1]; excl[1] = tmp }
            out = ""
            cur = first
            for (i = 0; i < n; i++) {
                if (excl[i] > cur) {
                    out = out (out == "" ? "" : ",") net "." cur "-" net "." (excl[i] - 1)
                }
                cur = excl[i] + 1
            }
            if (cur <= last) out = out (out == "" ? "" : ",") net "." cur "-" net "." last
            print out
        }
    '
}

# Everything the managed-IPv6 branch adds, undone.  Kept separate so both the
# standalone branch and the passthrough branch can call it: a prefix left
# advertised after a switch would race Android's own RA on the same segment.
# /ipv6 nd is matched by interface, not by comment -- RouterOS overwrites the
# comment on that table with its own status text (verified on-device), so a
# comment lookup silently finds nothing.
sync_ipv6_teardown_cli() {
    printf '/ipv6 firewall nat remove [find where comment="rosq-nat66"]\n'
    printf '/ipv6 nd remove [find where interface=%s]\n' "$ROS_LAN_IFACE"
    printf '/ipv6 nd set [find where interface=all] disabled=no\n'
    printf '/ipv6 address remove [find where comment="rosq-lan-ula"]\n'
    printf '/ipv6 settings set accept-router-advertisements=yes-if-forwarding-disabled\n'
}

sync_ipv6_managed_cli() {
    sync_ula="$(ros_ula_prefix)"
    sync_ula_addr="$sync_ula::1"
    # Start from the teardown so repeated syncs replace our objects instead of
    # stacking a second address/nd entry on the same interface.
    sync_ipv6_teardown_cli
    # CHR forwards, and the RouterOS default for this setting is
    # "yes-if-forwarding-disabled", i.e. RAs are ignored on a router.  Without
    # this the WAN NIC never SLAACs a global address and NAT66 has no source
    # address to translate to.
    printf '/ipv6 settings set forward=yes accept-router-advertisements=yes\n'
    printf '/ipv6 address add address=%s/64 interface=%s advertise=yes comment="rosq-lan-ula"\n' \
        "$sync_ula_addr" "$ROS_LAN_IFACE"
    # ra-lifetime matters more than it looks: Android 15+ sets
    # accept_ra_min_lft=180 and drops any RA advertising less.  RouterOS's 30m
    # default clears that bar; the host's ra6 helper (45s) does not, which is
    # why phones saw no IPv6 while laptops did.
    printf '/ipv6 nd add interface=%s ra-lifetime=30m advertise-dns=yes dns=%s comment="rosq-lan-nd"\n' \
        "$ROS_LAN_IFACE" "$sync_ula_addr"
    # The default entry covers "all" interfaces, which would also advertise
    # RouterOS as a router towards Android on the WAN link.
    printf '/ipv6 nd set [find where interface=all] disabled=yes\n'
    # Single carrier /64 and no prefix delegation, so the LAN ULA has to be
    # translated on the way out.
    printf '/ipv6 firewall nat add chain=srcnat out-interface=%s action=masquerade comment="rosq-nat66"\n' \
        "$ROS_WAN_IFACE"
}

sync_network_config() {
    load_config
    sync_ip="${1:-$LAN_GUEST_IP}"
    sync_mask="${2:-$LAN_NETMASK}"
    [ "$sync_mask" = 255.255.255.0 ] || die "当前版本仅支持 255.255.255.0"
    printf '%s\n' "$sync_ip" | awk -F. 'NF != 4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1}' >/dev/null 2>&1 || \
        die "无效的 IPv4 地址: $sync_ip"
    sync_addr="$sync_ip/24"
    sync_net="$(printf '%s\n' "$sync_ip" | awk -F. '{print $1 "." $2 "." $3}')"
    sync_lan_cidr="$sync_net.0/24"
    sync_guest_octet="$(printf '%s\n' "$sync_ip" | awk -F. '{print $4}')"
    sync_host_octet="$(printf '%s\n' "$LAN_HOST_IP" | awk -F. 'NF == 4 {print $4}')"
    case "$sync_host_octet" in ''|*[!0-9]*) sync_host_octet=-1 ;; esac
    # Fixed names so repeated syncs replace the plug-in's own objects and
    # leave anything the user created by hand alone.
    sync_pool_name=rosq-lan-pool
    sync_dhcp_name=rosq-lan-dhcp
    sync_pool_ranges="$(dhcp_pool_ranges "$sync_net" "$ROS_DHCP_POOL_START" "$ROS_DHCP_POOL_END" "$sync_guest_octet" "$sync_host_octet")"
    if [ "${STANDALONE:-0}" != 1 ] && [ "$ROS_DHCP_ENABLED" = 1 ] && [ -z "$sync_pool_ranges" ]; then
        die "DHCP 地址池为空：${ROS_DHCP_POOL_START}-${ROS_DHCP_POOL_END} 全被宿主/客户机地址占用，请调整 ROS_DHCP_POOL_START/END"
    fi
    sync_in="$VM_DIR/network-sync.in"
    sync_log="$VM_DIR/network-sync.log"
    {
        # Give the NICs meaningful names before anything references them.
        # "default-name" is read-only and keeps saying ether1/ether2 however
        # often the interface is renamed, so this is idempotent and also
        # repairs an install still carrying the original names.  Which NIC is
        # which follows from the qemu argument order (wan0 netdev first);
        # verified on-device: ether1 carries WAN_MAC, ether2 LAN_MAC.
        printf '/interface set [find default-name=ether1] name=%s\n' "$ROS_WAN_IFACE"
        printf '/interface set [find default-name=ether2] name=%s\n' "$ROS_LAN_IFACE"
        # Drop any previous plug-in-managed address on the LAN NIC first, so
        # changing LAN_GUEST_IP replaces the old one instead of stacking.
        printf '/ip address remove [find where interface=%s]\n' "$ROS_LAN_IFACE"
        printf '/ip address add address="%s" interface=%s\n' "$sync_addr" "$ROS_LAN_IFACE"
        # The uplink is ether1 in BOTH modes.  Routing out through the LAN
        # bridge instead does not work: the host only installs
        # "iif ros-wan lookup <upstream>" and only masquerades WAN_SUBNET, so
        # traffic leaving via ros-br has neither a policy route nor NAT.
        printf '/ip address remove [find where interface=%s]\n' "$ROS_WAN_IFACE"
        printf '/ip address add address="%s/24" interface=%s\n' "$WAN_GUEST_IP" "$ROS_WAN_IFACE"
        printf '/ip route remove [find where dst-address="0.0.0.0/0" && static]\n'
        printf '/ip route add dst-address=0.0.0.0/0 gateway=%s\n' "$WAN_HOST_IP"
        # Nothing on ros-wan answers DNS, so the guest needs real resolvers.
        [ -z "$ROS_DNS" ] || printf '/ip dns set servers=%s\n' "$ROS_DNS"
        if [ "${STANDALONE:-0}" = 1 ]; then
            # Standalone: only RouterOS's own traffic leaves, sourced from
            # WAN_GUEST_IP, which the host already masquerades.  No guest-side
            # NAT needed, and no client traffic transits.
            #
            # Android serves DHCP again in this mode, so a server left over
            # from gateway mode would be a second one on the same L2 segment.
            # Tear it down rather than let the two fight over clients.
            printf '/ip dhcp-server remove [find where name="%s"]\n' "$sync_dhcp_name"
            printf '/ip dhcp-server network remove [find where address="%s"]\n' "$sync_lan_cidr"
            printf '/ip pool remove [find where name="%s"]\n' "$sync_pool_name"
            # Undo the rest of what the gateway branch adds, so switching back
            # and forth is symmetric instead of accumulating leftovers.  The
            # masquerade is a no-op here (RouterOS's own traffic already
            # leaves as WAN_GUEST_IP) but it is ours, so we clean it up.
            printf '/ip firewall nat remove [find where chain="srcnat" && out-interface="%s" && action="masquerade"]\n' "$ROS_WAN_IFACE"
            # No clients on this segment in standalone mode, so RouterOS has
            # no reason to answer DNS for anyone but itself.
            printf '/ip dns set allow-remote-requests=no\n'
            sync_ipv6_teardown_cli
        else
            # Android only masquerades WAN_SUBNET, so client traffic has to
            # leave RouterOS already translated to WAN_GUEST_IP or it is
            # dropped on the host side.
            printf ':if ([:len [/ip firewall nat find where chain="srcnat" && out-interface="%s" && action="masquerade"]] = 0) do={ /ip firewall nat add chain=srcnat out-interface=%s action=masquerade }\n' "$ROS_WAN_IFACE" "$ROS_WAN_IFACE"
            if [ "$ROS_DHCP_ENABLED" = 1 ]; then
                # setup_network flushes the tether interfaces' addresses and
                # DROPs Android's DHCP replies in this mode, so RouterOS is
                # the only thing left that can hand out leases.
                # Remove-then-add keeps repeated syncs from stacking; the
                # server goes first because the pool cannot be removed while
                # it is still referenced.
                printf '/ip dhcp-server remove [find where name="%s"]\n' "$sync_dhcp_name"
                printf '/ip dhcp-server network remove [find where address="%s"]\n' "$sync_lan_cidr"
                printf '/ip pool remove [find where name="%s"]\n' "$sync_pool_name"
                printf '/ip pool add name=%s ranges=%s\n' "$sync_pool_name" "$sync_pool_ranges"
                # Clients resolve through RouterOS, which needs to answer
                # queries from the LAN for that to work.
                printf '/ip dns set allow-remote-requests=yes\n'
                printf '/ip dhcp-server network add address=%s gateway=%s dns-server=%s\n' \
                    "$sync_lan_cidr" "$sync_ip" "$sync_ip"
                printf '/ip dhcp-server add name=%s interface=%s address-pool=%s lease-time=%s disabled=no\n' \
                    "$sync_dhcp_name" "$ROS_LAN_IFACE" "$sync_pool_name" "$ROS_DHCP_LEASE"
            fi
            if [ "$IPV6_PASSTHROUGH" = 1 ]; then
                # Android keeps owning downstream IPv6 in passthrough mode, so
                # RouterOS must not advertise a competing prefix.
                sync_ipv6_teardown_cli
            else
                sync_ipv6_managed_cli
            fi
        fi
        printf ':if ([:len [/ip address find where address="%s"]] > 0) do={ :put "__NETWORK_SYNC_OK__" } else={ :put "__NETWORK_SYNC_ERROR__=address not applied" }\n' "$sync_addr"
        printf '/system shutdown\n'
        # /system shutdown is interactive: answer its [y/N] prompt.
        printf 'y\n'
    } > "$sync_in"
    maint_run "$sync_in" "$sync_log" >/dev/null || die "维护模式启动失败（日志：$sync_log）"
    if grep -aq '__NETWORK_SYNC_OK__' "$sync_log"; then
        echo "__NETWORK_SYNC_OK__"
        echo "RouterOS LAN 地址已写入磁盘: $sync_addr ($ROS_LAN_IFACE)"
        return 0
    fi
    sync_reason="$(sed -n 's/.*__NETWORK_SYNC_ERROR__=//p' "$sync_log" | tr -d '\r' | head -n 1)"
    die "网络同步失败：${sync_reason:-未收到成功标记（日志：$sync_log）}"
}

# Entry point for /sdcard/ufi_tools_boot.sh.  Two things differ from a plain
# "start": it honours BOOT_DELAY, and it never blocks the boot script -- the
# wait happens in a detached child so the rest of the device's boot tasks are
# not held up for as long as the user configured.
#
# A delay is worth having because at boot time the cellular link, the hotspot
# and the USB gadget are all still coming up; starting the VM into that races
# setup_network against interfaces that keep changing underneath it.
boot_start() {
    load_config
    resolve_device_config
    if [ "$BOOT_DELAY" -gt 0 ]; then
        nohup sh -c 'sleep "$1"; "$2" start' _ "$BOOT_DELAY" "$MANAGER_SELF" \
            </dev/null >>"$LOG" 2>&1 &
        echo "boot: RouterOS VM start scheduled in ${BOOT_DELAY}s"
        return 0
    fi
    start_vm
}

case "${1:-}" in
    __network_monitor) network_monitor ;;
    __vm_watchdog) vm_watchdog "$2" ;;
    start) start_vm ;;
    boot) boot_start ;;
    stop) stop_vm ;;
    restart) stop_vm; start_vm ;;
    status) status_vm ;;
    preflight) preflight_vm ;;
    qemu-path)
        load_config
        resolve_qemu_path
        printf '%s\n' "$QEMU"
        ;;
    firmware-path)
        load_config
        resolve_qemu_path
        resolve_firmware
        printf '%s\n' "$FIRMWARE"
        ;;
    version) printf '%s\n' "$MANAGER_VERSION" ;;
    refresh-ipv6) refresh_ipv6 ;;
    logs) tail -n "${2:-200}" "$LOG" 2>/dev/null; echo "--- guest console ---"; tail -n "${2:-200}" "$CONSOLE" 2>/dev/null ;;
    console-write) console_write "${2:-}" ;;
    maint) maint_run "${2:-}" "${3:-}" ;;
    sync-network) sync_network_config "${2:-}" "${3:-}" ;;
    forwards) list_forwards ;;
    disk-info) show_disk_info ;;
    disk-resize) resize_disk "${2:-}" "${3:-expand}" ;;
    disk-reclaim) reclaim_disk ;;
    backup) backup_vm "${2:-}" ;;
    backups) list_backups ;;
    restore-backup) restore_backup "${2:-}" ;;
    delete-backup) delete_backup "${2:-}" ;;
    ttyd-restart) load_config; resolve_qemu_path; stop_ttyd; start_ttyd; is_ttyd_running && echo "ttyd http://$TTYD_BIND:$TTYD_PORT/" || echo 'ttyd 未运行' ;;
    ttyd-stop) load_config; stop_ttyd; echo 'ttyd 已停止，虚拟机继续运行' ;;
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
    *)
        echo "usage: $0 {start|boot|stop|restart|status|preflight|version" >&2
        echo "          |qemu-path|firmware-path|refresh-ipv6|logs [lines]" >&2
        echo "          |console-write BASE64|maint INFILE LOGFILE|sync-network [IP] [MASK]" >&2
        echo "          |forwards|disk-info|disk-resize GIB [expand]|disk-reclaim" >&2
        echo "          |backup NAME|backups|restore-backup DIR|delete-backup DIR" >&2
        echo "          |ttyd-restart|ttyd-stop" >&2
        echo "          |usb {list|attach NAME|detach PORT|auto {add VID:PID|del VID:PID}}" >&2
        echo "          |takeover|untakeover|uninstall}" >&2
        exit 2
        ;;
esac
