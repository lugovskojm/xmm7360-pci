#!/usr/bin/env bash
# xmm7360-up.sh — bring wwan0 up fully after open_xdatachannel.py.
#
# Usage: sudo ./scripts/xmm7360-up.sh [apn]
#        default APN: internet (pass something like internet.mts.ru)
#
# This wraps the five post-bring-up steps that the driver alone doesn't do:
#   1. Run rpc/open_xdatachannel.py to establish the PDP/datachannel
#   2. Re-add the assigned IPv4 with peer 0.0.0.0/0 so the kernel creates
#      a RTN_LOCAL entry (fixes bind(IP) -> EADDRNOTAVAIL)
#   3. Disable rp_filter so return packets aren't dropped by strict RPF
#   4. NOTRACK wwan0 in iptables raw (conntrack marks returns INVALID
#      without a peer MAC, UFW's before-input rule then drops them)
#   5. Policy routing: pin packets with src=<wwan IP> to a dedicated
#      table so they always egress wwan0, even when a wifi default
#      route has a better metric
#
# Intended to be run once after every successful datachannel setup.

set -euo pipefail

APN="${1:-internet}"
IFACE="wwan0"
TABLE="wwan"
TABLE_ID=200
RT_TABLES_FILE=/etc/iproute2/rt_tables

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root (sudo)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0. Prerequisite: custom routing table name registered
# ---------------------------------------------------------------------------
mkdir -p /etc/iproute2
if [[ ! -f $RT_TABLES_FILE ]] || ! grep -q "^${TABLE_ID}[[:space:]]\+${TABLE}" "$RT_TABLES_FILE"; then
    cat > "$RT_TABLES_FILE" <<EOF
255     local
254     main
253     default
${TABLE_ID}     ${TABLE}
0       unspec
EOF
    echo "Wrote $RT_TABLES_FILE"
fi

# ---------------------------------------------------------------------------
# 1. Bring up the datachannel via RPC
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC_DIR="${SCRIPT_DIR}/../rpc"
if [[ ! -x "$RPC_DIR/open_xdatachannel.py" ]]; then
    # try the installed location
    RPC_DIR="/usr/share/xmm7360-pci/rpc"
fi

echo "==> Starting datachannel via ${RPC_DIR}/open_xdatachannel.py -a ${APN}"
python3 "${RPC_DIR}/open_xdatachannel.py" -a "$APN" 2>&1 | tail -40 &
RPC_PID=$!

# Give the RPC script some time to obtain an address
sleep 8

MY_IP=$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
if [[ -z "$MY_IP" ]]; then
    echo "No IPv4 on $IFACE yet, waiting another 10s..."
    sleep 10
    MY_IP=$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
fi

if [[ -z "$MY_IP" ]]; then
    echo "ERROR: could not determine $IFACE IPv4 address. Check open_xdatachannel.py output above." >&2
    kill "$RPC_PID" 2>/dev/null || true
    exit 2
fi
echo "==> $IFACE has $MY_IP"

# ---------------------------------------------------------------------------
# 2. Re-add IP with peer so kernel treats it as RTN_LOCAL
# ---------------------------------------------------------------------------
ip addr flush dev "$IFACE"
ip addr add "$MY_IP" peer 0.0.0.0/0 dev "$IFACE"
ip link set "$IFACE" up

# ---------------------------------------------------------------------------
# 3. Sysctl: disable rp_filter on wwan0 and all
# ---------------------------------------------------------------------------
sysctl -q -w "net.ipv4.conf.${IFACE}.rp_filter=0"
sysctl -q -w net.ipv4.conf.all.rp_filter=0

# ---------------------------------------------------------------------------
# 4. iptables: NOTRACK on wwan0 (idempotent)
# ---------------------------------------------------------------------------
iptables -t raw -C PREROUTING -i "$IFACE" -j CT --notrack 2>/dev/null || \
    iptables -t raw -I PREROUTING -i "$IFACE" -j CT --notrack
iptables -t raw -C OUTPUT -o "$IFACE" -j CT --notrack 2>/dev/null || \
    iptables -t raw -I OUTPUT -o "$IFACE" -j CT --notrack

# ---------------------------------------------------------------------------
# 5. Policy routing: table ${TABLE} + rule from <MY_IP>
# ---------------------------------------------------------------------------
ip route flush table "$TABLE" 2>/dev/null || true
ip route add default dev "$IFACE" scope link table "$TABLE"

# Remove any stale rule, then add fresh
ip rule del from "$MY_IP" 2>/dev/null || true
ip rule add from "$MY_IP" table "$TABLE" priority 100

# Also add a low-priority default via wwan0 in main (metric 4242) so that
# `-I wwan0` works even when the app doesn't bind a source IP.
ip route replace default dev "$IFACE" scope link metric 4242

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo
echo "=== State ==="
ip -br addr show "$IFACE"
echo "--- rules ---"
ip rule show | grep -E "(priority|wwan)" | head -20
echo "--- table $TABLE ---"
ip route show table "$TABLE"
echo "--- route lookup ---"
ip route get 1.1.1.1 from "$MY_IP"
echo

echo "=== ping test ==="
if ping -c 3 -W 3 -I "$IFACE" 1.1.1.1 >/dev/null 2>&1; then
    RTT=$(ping -c 3 -W 3 -I "$IFACE" 1.1.1.1 | awk -F'/' '/rtt/ {print $5}')
    echo "OK: ping via $IFACE works (avg ${RTT} ms)"
else
    echo "FAIL: ping -I $IFACE 1.1.1.1 did not get a reply" >&2
    exit 3
fi

echo
echo "Bring-up complete. open_xdatachannel.py is running as PID $RPC_PID."
echo "Keep this terminal open to maintain the PDP session (Ctrl+C to tear down)."
wait "$RPC_PID"
