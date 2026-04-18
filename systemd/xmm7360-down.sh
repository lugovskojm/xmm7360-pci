#!/usr/bin/env bash
# xmm7360-down.sh — tear down LTE routing/rules set up by xmm7360-up.sh.
# Called as systemd ExecStop. Idempotent: safe to run when nothing is up.
set -u

IFACE="wwan0"
TABLE="wwan"

# Delete any policy-routing rules that point at our custom table
while ip rule show | grep -q "lookup ${TABLE}"; do
    ip rule del table "${TABLE}" 2>/dev/null || break
done

# Flush the table
ip route flush table "${TABLE}" 2>/dev/null || true

# Remove the NOTRACK rules
iptables -t raw -D PREROUTING -i "${IFACE}" -j CT --notrack 2>/dev/null || true
iptables -t raw -D OUTPUT    -o "${IFACE}" -j CT --notrack 2>/dev/null || true

# Flush the interface address and drop its default route from main
ip addr flush dev "${IFACE}" 2>/dev/null || true
ip route del default dev "${IFACE}" 2>/dev/null || true

# Let the interface go down — the kernel module stays loaded
ip link set "${IFACE}" down 2>/dev/null || true

exit 0
