# xmm7360-pci on ThinkPad X280 + Omarchy (ArchLinux)

This branch patches the upstream xmm7360-pci driver so it builds and runs on
modern Linux kernels (6.6 → 6.15+) that ship with current Omarchy / Arch
installs, and documents the X280-specific bits (Fibocom L850-GL modem).

## What changed

| Area                          | Fix                                                                          |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `tty_operations.write`        | New 6.6+ signature `ssize_t write(struct tty_struct*, const u8*, size_t)`    |
| `tty_operations.write_room`   | Return type now `unsigned int`                                               |
| `hrtimer_init`                | Switched to `hrtimer_setup()` on 6.15+ (upstream removed `hrtimer_init`)     |
| `probe()` NPE                 | `!xmm` check moved *before* first dereference                                |
| `Makefile reset` target       | PCI slot auto-detected via `lspci -d 8086:7360`, ACPI path parameterized     |
| `dkms.conf`                   | Shipped directly (no template) — works with Arch DKMS out of the box         |
| `PKGBUILD`                    | Installable via `makepkg -si`                                                |
| **RX local delivery (6.x)**   | `skb_reset_mac_header` / `skb_reset_network_header` / `pkt_type=PACKET_HOST` so echo replies reach the ICMP socket (without this `ping -I wwan0` sees 100% loss while tcpdump sees replies) |
| **`make reset` on X280**      | Default is `rmmod + modprobe` only. `reset-pci` and `reset-acpi` are kept but marked dangerous — both freeze X280 because RP09 shares a power rail with the Thunderbolt controller |

All changes are guarded by `LINUX_VERSION_CODE` so the module still builds on
older kernels (5.4 – 6.5).

## Install on Omarchy

```sh
sudo pacman -S --needed base-devel dkms linux-headers acpi_call-dkms \
                         python python-pyroute2 git

git clone -b omarchy-x280 https://github.com/<your-fork>/xmm7360-pci.git
cd xmm7360-pci
makepkg -si            # builds + installs via DKMS

# Prevent the in-tree iosm driver from binding first
echo "blacklist iosm" | sudo tee /etc/modprobe.d/xmm7360.conf

sudo rmmod iosm 2>/dev/null
sudo modprobe xmm7360
```

Or without DKMS, for a quick test:

```sh
make            # build
sudo make load  # unload iosm, insmod xmm7360
```

## X280-specific notes

- Modem is a **Fibocom L850-GL** on PCIe, `8086:7360`, and on X280 it sits
  behind Root Port `RP09` — this is why `make reset` defaults to
  `\_SB.PCI0.RP09.PXSX._RST`. If your firmware enumerates differently, find
  it in `/sys/firmware/acpi/tables/DSDT` (decompile with `iasl -d`) and pass
  `ACPI_PATH='…'` on the Make command line.
- PCI slot on X280 is typically `0000:02:00.0` (not `0000:3b:00.0` like on
  X1 Carbon). The Makefile now autodetects it with `lspci`.
- You need a working SIM with LTE/3G data and the correct APN. Fill in
  `xmm7360.ini` (or pass `-a <apn>` to `open_xdatachannel.py`).

## Bring up data

```sh
sudo ./rpc/open_xdatachannel.py -a internet.mts.ru   # replace with your APN
# interface wwan0 should get an IPv4 address
```

You should see these three RPC calls succeed:
- `UtaMsCallPsConnectReq` — PDP context
- `UtaRPCPsConnectToDatachannelReq` → `0x20017`
- `UtaRPCPSConnectSetupReq` → `0x0`

### Post-bring-up networking (tested on X280 + MTS Russia)

The driver exposes `wwan0` as a raw-IP POINTOPOINT device without L2. On
kernel 6.x you may need the following to get traffic flowing:

```sh
# 1. Re-add the IP with a peer so the kernel creates a RTN_LOCAL entry
#    (otherwise bind(IP) returns EADDRNOTAVAIL and some apps can't use wwan0)
MY_IP=$(ip -br addr show wwan0 | awk '{print $3}' | cut -d/ -f1)
sudo ip addr flush dev wwan0
sudo ip addr add "${MY_IP}" peer 0.0.0.0/0 dev wwan0
sudo ip link set wwan0 up
sudo ip route replace default dev wwan0 scope link metric 4242

# 2. Ensure the kernel delivers return packets to the ICMP socket
#    (rp_filter + conntrack INVALID often drop them on UFW systems)
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.wwan0.rp_filter=0

# 3. Bypass conntrack on wwan0 (the interface has no peer MAC, which
#    confuses conntrack and it marks returning packets INVALID)
sudo iptables -t raw -I PREROUTING -i wwan0 -j CT --notrack
sudo iptables -t raw -I OUTPUT    -o wwan0 -j CT --notrack

ping -c 3 -I wwan0 1.1.1.1
curl --interface wwan0 -s https://ifconfig.me
```

To make the sysctl/iptables changes persistent:

```sh
sudo tee /etc/sysctl.d/99-xmm7360.conf <<'EOF'
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.wwan0.rp_filter   = 0
EOF
sudo sysctl --system
```

Or configure NetworkManager:

```sh
sudo nmcli connection add type gsm ifname wwan0 con-name mobile apn internet.mts.ru
sudo nmcli connection up mobile
```

## If it still fails

1. `dmesg | grep -E 'xmm7360|iosm'` — look for bind conflicts (iosm must
   be blacklisted; the PKGBUILD installs `/usr/lib/modprobe.d/xmm7360.conf`).
2. `lspci -vv -d 8086:7360` — confirm the modem is detected and the root
   port is not in D3.
3. `tcpdump -ni wwan0 icmp` while pinging — if you see reply packets but
   ping reports 100% loss, you are missing the RX headers fix from this
   branch: rebuild and reinstall.
4. **Do not** `make reset-acpi` or `make reset-pci` on X280 — both freeze
   the system. Use `make reset` (module reload) or `systemctl reboot`.
5. Compare your ACPI path for *other* laptops: `grep -r 'PXSX' /sys/firmware/acpi/`.
