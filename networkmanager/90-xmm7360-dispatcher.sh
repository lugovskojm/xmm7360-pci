#!/bin/bash
# NetworkManager dispatcher hook for the xmm7360 modem.
# Path on disk: /etc/NetworkManager/dispatcher.d/90-xmm7360
#
# Events:
#   wwan0 up     -> ensure our service is running (PDP session + addr)
#   wwan0 pre-down -> stop the service so the modem tears down cleanly
#
# NM runs this as root with:
#   $1 = interface name
#   $2 = action (up, down, pre-up, pre-down, vpn-up, vpn-down, connectivity-change, ...)

set -euo pipefail

IFACE="${1:-}"
ACTION="${2:-}"

# Only act on wwan0
[[ "$IFACE" == "wwan0" ]] || exit 0

case "$ACTION" in
    up)
        # Kickstart the systemd service if nobody brought the modem up yet.
        # If it's already running, this is a no-op.
        if ! systemctl is-active --quiet xmm7360.service; then
            logger -t xmm7360-nm "wwan0 up event, starting xmm7360.service"
            systemctl start --no-block xmm7360.service || true
        fi
        ;;
    pre-down|down)
        # `nmcli con down xmm7360` or reboot — tear down gracefully
        if systemctl is-active --quiet xmm7360.service; then
            logger -t xmm7360-nm "wwan0 $ACTION event, stopping xmm7360.service"
            systemctl stop --no-block xmm7360.service || true
        fi
        ;;
esac

exit 0
