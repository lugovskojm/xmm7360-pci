#!/usr/bin/env bash
# xmm7360-up.sh — bring wwan0 up fully after open_xdatachannel.py.
#
# Usage: sudo ./scripts/xmm7360-up.sh [apn]
#        default APN: internet (override per your SIM, e.g. internet.mts.ru)
#
# Works both standalone (keeps open_xdatachannel.py in foreground so the
# PDP session is alive) and under systemd (trap SIGTERM -> graceful shutdown).
#
# Post-bring-up steps this script performs:
#   1. Register custom routing table 'wwan' (id 200) in /etc/iproute2/rt_tables
#   2. Run rpc/open_xdatachannel.py -a <APN>
#   3. Re-add the IP with 'peer 0.0.0.0/0' so kernel creates RTN_LOCAL
#      (fixes bind(IP) -> EADDRNOTAVAIL on raw-IP POINTOPOINT interfaces)
#   4. sysctl rp_filter=0 on wwan0 and all
#   5. iptables -t raw CT --notrack on wwan0 (bypass conntrack INVALID)
#   6. Policy routing: pin packets with src=<wwan_ip> to table 'wwan',
#      plus a metric-4242 default via wwan0 in the main table

set -uo pipefail

APN="${1:-internet}"
IFACE="wwan0"
TABLE="wwan"
TABLE_ID=200
RT_TABLES_FILE=/etc/iproute2/rt_tables
PIDFILE=/run/xmm7360.pid

if [[ $EUID -ne 0 ]]; then
    echo "xmm7360-up.sh: must run as root" >&2
    exit 1
fi

log() { echo "[xmm7360-up] $*"; }

# --- Cleanup handler -------------------------------------------------------
cleanup() {
    trap '' TERM INT
    log "shutting down..."
    if [[ -n "${RPC_PID:-}" ]] && kill -0 "$RPC_PID" 2>/dev/null; then
        kill "$RPC_PID" 2>/dev/null || true
        wait "$RPC_PID" 2>/dev/null || true
    fi
    # Let xmm7360-down.sh (or systemd ExecStop) handle rule/route teardown.
    # We only remove our PID file here.
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup TERM INT

# --- 0. Register the routing table name -----------------------------------
mkdir -p /etc/iproute2
if [[ ! -f $RT_TABLES_FILE ]] || ! grep -q "^${TABLE_ID}[[:space:]]\+${TABLE}" "$RT_TABLES_FILE"; then
    cat > "$RT_TABLES_FILE" <<EOF
255     local
254     main
253     default
${TABLE_ID}     ${TABLE}
0       unspec
EOF
    log "wrote $RT_TABLES_FILE"
fi

# --- 1. Locate open_xdatachannel.py ----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in \
    "${SCRIPT_DIR}/../rpc/open_xdatachannel.py" \
    "/usr/share/xmm7360-pci/rpc/open_xdatachannel.py" \
    "/usr/lib/xmm7360-pci/rpc/open_xdatachannel.py" \
    ; do
    if [[ -f "$candidate" ]]; then
        RPC_SCRIPT="$candidate"
        break
    fi
done
if [[ -z "${RPC_SCRIPT:-}" ]]; then
    log "ERROR: cannot find open_xdatachannel.py" >&2
    exit 2
fi
RPC_DIR="$(dirname "$RPC_SCRIPT")"

# --- 2. Make sure module is loaded + interface exists ---------------------
if ! lsmod | grep -q '^xmm7360 '; then
    log "module not loaded, modprobing..."
    modprobe xmm7360 || { log "ERROR: modprobe xmm7360 failed" >&2; exit 3; }
    sleep 2
fi
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -d "/sys/class/net/$IFACE" ]] && break
    sleep 1
done
if [[ ! -d "/sys/class/net/$IFACE" ]]; then
    log "ERROR: $IFACE never appeared after modprobe" >&2
    exit 4
fi

# --- 3. Kick off open_xdatachannel.py in background -----------------------
log "starting datachannel: $RPC_SCRIPT -a $APN"
cd "$RPC_DIR"
python3 "$RPC_SCRIPT" -a "$APN" &
RPC_PID=$!
echo "$RPC_PID" > "$PIDFILE"

# Wait up to 30s for IPv4 to show up
MY_IP=""
for i in {1..30}; do
    MY_IP=$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
    [[ -n "$MY_IP" ]] && break
    if ! kill -0 "$RPC_PID" 2>/dev/null; then
        log "ERROR: open_xdatachannel.py exited before IPv4 was assigned" >&2
        exit 5
    fi
    sleep 1
done

if [[ -z "$MY_IP" ]]; then
    log "ERROR: $IFACE never got an IPv4 address" >&2
    kill "$RPC_PID" 2>/dev/null || true
    exit 6
fi
log "$IFACE has $MY_IP"

# --- 4. Re-add address with peer so bind(IP) works ------------------------
ip addr flush dev "$IFACE"
ip addr add "$MY_IP" peer 0.0.0.0/0 dev "$IFACE"
ip link set "$IFACE" up

# --- 5. sysctl: disable rp_filter on wwan0 + all --------------------------
sysctl -q -w "net.ipv4.conf.${IFACE}.rp_filter=0" || true
sysctl -q -w net.ipv4.conf.all.rp_filter=0 || true

# --- 6. iptables NOTRACK on wwan0 (idempotent) ----------------------------
iptables -t raw -C PREROUTING -i "$IFACE" -j CT --notrack 2>/dev/null || \
    iptables -t raw -I PREROUTING -i "$IFACE" -j CT --notrack
iptables -t raw -C OUTPUT -o "$IFACE" -j CT --notrack 2>/dev/null || \
    iptables -t raw -I OUTPUT -o "$IFACE" -j CT --notrack

# --- 7. Policy routing + low-prio default ---------------------------------
ip route flush table "$TABLE" 2>/dev/null || true
ip route add default dev "$IFACE" scope link table "$TABLE"

# replace stale source-based rule
while ip rule show | grep -q "from ${MY_IP} lookup ${TABLE}"; do
    ip rule del from "$MY_IP" table "$TABLE" 2>/dev/null || break
done
ip rule add from "$MY_IP" table "$TABLE" priority 100

# metric-4242 default so `-I wwan0` works without explicit source
ip route replace default dev "$IFACE" scope link metric 4242

# --- 8. Verify -------------------------------------------------------------
log "=== state ==="
ip -br addr show "$IFACE"
ip route get 1.1.1.1 from "$MY_IP" 2>/dev/null || true

if ping -c 2 -W 3 -I "$IFACE" 1.1.1.1 >/dev/null 2>&1; then
    log "bring-up OK: ping via $IFACE works"
else
    log "WARNING: ping via $IFACE failed, but datachannel is up (check upstream)"
fi

# --- 9. Stay in foreground so PDP session lives ---------------------------
log "holding PDP session (pid $RPC_PID), Ctrl+C or 'systemctl stop xmm7360' to tear down"
wait "$RPC_PID"
RC=$?
log "open_xdatachannel.py exited with code $RC"
rm -f "$PIDFILE"
exit "$RC"
