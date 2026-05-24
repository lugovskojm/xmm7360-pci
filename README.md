# xmm7360-pci — modernized fork

A maintained fork of [xmm7360/xmm7360-pci](https://github.com/xmm7360/xmm7360-pci)
that builds and runs cleanly on current Linux kernels and ships a complete
Arch-family package with systemd integration.

Upstream hasn't seen a release in years; every Linux release since 5.6 or so
broke something. This fork collects the fixes in one branch so the driver
actually works in 2026.

> This is an unofficial community fork. Not affiliated with Intel, Fibocom,
> or upstream xmm7360. Use at your own risk.

---

## What's fixed

### Kernel compatibility

| Kernel API                     | Change                                                                                                    |
| ------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `tty_operations.write` (6.6+)  | New signature `ssize_t write(struct tty_struct *, const u8 *, size_t)`                                    |
| `tty_operations.write_room` (6.6+) | Return type is now `unsigned int`                                                                     |
| `hrtimer_init` (6.15+)         | Replaced with `hrtimer_setup()` (upstream function was removed)                                           |
| `probe()` null check           | `!xmm` guard moved before the first dereference, fixes a boot-time NPE some users hit                      |

All changes are guarded with `LINUX_VERSION_CODE` so the module still builds
on older kernels (5.4 through 6.5) unchanged.

### RX path

Without this fix, `ping -I wwan0` reports 100% loss even though `tcpdump -i wwan0`
shows replies arriving. This is a regression that appeared on kernel 6.x: the
stack stopped handing raw-IP frames to local sockets unless the driver resets
the SKB headers and explicitly sets `pkt_type = PACKET_HOST`.

In `xmm7360_net_rx()`:

```c
skb_reset_mac_header(skb);
skb_reset_network_header(skb);
skb->ip_summed = CHECKSUM_NONE;
skb->pkt_type  = PACKET_HOST;
```

### Userspace helper (`rpc/open_xdatachannel.py`)

- Replaced all pyroute2 `addr`/`route`/`flush_addr` calls with direct
  `ip` CLI invocations. pyroute2 0.7+ on Python 3.14 crashes inside its own
  `requests/address.py` when netlink returns any address field as `None`.
- Filter `None`, empty, `0.0.0.0`, `::` entries out of the DNS list before
  joining — carriers that return only IPv4 DNS used to crash the script with
  `AttributeError: 'NoneType' object has no attribute 'find'`.
- No longer `sys.exit(1)` after `UtaRPCPSConnectSetupReq` in non-dbus mode.
  On some firmware/APN combinations that RPC returns `0xffffffff` even when
  the datachannel is actually up. We log a warning and keep the PDP session
  alive with SIGTERM/SIGINT handlers instead of dropping the link.
- Graceful `/etc/resolv.conf` write (doesn't crash if the file is immutable
  or managed by systemd-resolved).

### Bring-up script (`scripts/xmm7360-up.sh`)

A self-contained wrapper that:

1. Loads the module if it isn't loaded, waits for `wwan0` to appear.
2. Starts `open_xdatachannel.py` with the configured APN.
3. Waits up to 30s for an IPv4 address on `wwan0`.
4. Re-adds the address with `peer 0.0.0.0/0` so the kernel creates an
   `RTN_LOCAL` entry. Without this, `bind(IP)` returns `EADDRNOTAVAIL` and
   many apps can't use the interface.
5. Sets `rp_filter=0` on `wwan0` and `all` (raw-IP + faster wifi default
   route otherwise cause the kernel to reverse-path-filter return packets).
6. Installs idempotent `iptables -t raw CT --notrack` rules on `wwan0`
   (bypasses the conntrack INVALID drop that UFW-style firewalls enforce).
7. Registers a custom routing table (`wwan`, id 200) and a source-based rule
   `from <wwan_ip> lookup wwan`, plus a high-metric default via `wwan0` in
   the main table — so `ping -I wwan0` works without policy routing tripping
   over the stronger wifi route.
8. Verifies connectivity with a single `ping`, then holds the PDP session
   open in the foreground. On SIGTERM (e.g. `systemctl stop`) the trap
   cleanly kills the RPC process.

### systemd integration

- `xmm7360.service` — oneshot-style unit (type `simple`) running the
  bring-up script.
- `xmm7360-down.sh` — ExecStop tears down routes, rules, iptables entries,
  flushes the address, and unloads the module.
- `Restart=on-failure` with 5s backoff. Combined with the "don't exit on
  0xffffffff" fix above, the service reaches `active (running)` on the
  first try.
- `/etc/default/xmm7360` holds the APN (`XMM7360_APN=...`), added to
  `backup=` in the PKGBUILD so it survives upgrades.

### Packaging

- `dkms.conf` is shipped directly (no template) — the module rebuilds
  automatically on kernel upgrades.
- `PKGBUILD` installs cleanly with `makepkg -si`. Files go to standard
  locations:
  - kernel sources → `/usr/src/xmm7360-pci-<ver>/`
  - python helpers → `/usr/share/xmm7360-pci/`
  - bring-up scripts → `/usr/lib/xmm7360-pci/`
  - systemd unit → `/usr/lib/systemd/system/xmm7360.service`
  - udev rule → `/usr/lib/udev/rules.d/80-xmm7360.rules`
  - modprobe blacklist → `/usr/lib/modprobe.d/xmm7360.conf` (keeps `iosm`
    out of the way)
  - persistent sysctl → `/usr/lib/sysctl.d/99-xmm7360.conf`
- `__pycache__` and `.pyc` files are stripped on install, so rebuilds
  don't collide.

### Reset targets (Makefile)

The `reset-pci` / `reset-acpi` Make targets are kept but **marked dangerous**.
On some laptops the modem shares a PCIe root port with Thunderbolt, and
issuing a function-level reset or ACPI `_RST` freezes the machine hard. The
default `make reset` is now just `rmmod xmm7360 && modprobe xmm7360`, which
is safe everywhere.

If you want the old behaviour: `make reset-pci` or `make reset-acpi` — but
test it once from a TTY, not from a desktop session, and confirm your
machine survives before relying on it.

---

## Install (Arch / Manjaro / EndeavourOS / Omarchy)

```sh
sudo pacman -S --needed base-devel dkms linux-headers acpi_call-dkms \
                         python python-pyroute2 git

git clone https://github.com/lugovskojm/xmm7360-pci.git
cd xmm7360-pci
makepkg -si
```

Set your APN:

```sh
sudo sed -i 's/^XMM7360_APN=.*/XMM7360_APN=your.carrier.apn/' /etc/default/xmm7360
```

Start and enable:

```sh
sudo systemctl enable --now xmm7360
systemctl status xmm7360
ping -I wwan0 1.1.1.1
```

On other distros (Debian/Ubuntu/Fedora), use the helpers directly:

```sh
make                                    # build the module
sudo make load                          # unload iosm, insmod xmm7360
sudo ./scripts/xmm7360-up.sh your.apn   # bring up data
```

---

## Usage

```sh
sudo systemctl start xmm7360      # bring modem up
sudo systemctl stop xmm7360       # tear it down
sudo systemctl restart xmm7360    # reconnect
systemctl status xmm7360          # check state
journalctl -u xmm7360 -f          # follow logs
```

To change APN: edit `/etc/default/xmm7360`, then `systemctl restart xmm7360`.

---

## Troubleshooting

**`wwan0` never appears after `systemctl start`:**
- `dmesg | grep -E 'xmm7360|iosm'` — if `iosm` bound first, the blacklist
  didn't apply. `sudo rmmod iosm && sudo modprobe xmm7360`.
- `lspci -vv -d 8086:7360` — confirm the modem is detected. If it's in D3
  and won't come out, the root port may be power-gated — try a full reboot
  rather than module reload.

**`ping -I wwan0` reports 100% loss, but `tcpdump` sees replies:**
- You're missing the RX headers fix. Rebuild and reinstall (this fork has it).

**`AttributeError: 'NoneType' object has no attribute 'find'`:**
- You're on pyroute2 0.7+ / Python 3.14 with an IPv4-only APN. The fork has
  both fixes; make sure you installed from this branch, not upstream.

**Service exits with code 1 but ping works:**
- Old behaviour. Updated `open_xdatachannel.py` keeps the process alive
  after `UtaRPCPSConnectSetupReq` regardless of its return code.

**NetworkManager spams the log with "unmanaged-link-not-init":**
- The shipped udev rule sets `NM_UNMANAGED=1` on `wwan0` so NM ignores it.
  If you see this, `udevadm control --reload-rules && udevadm trigger`.

**Can I manage this through NetworkManager?**
- No. NM can't handle raw-IP POINTOPOINT/NOARP interfaces; its state
  machine errors out at `ip-check` regardless of any keyfile coaxing.
  Use the systemd service. If you want GUI integration, wrap `systemctl`
  in a small desktop launcher.

**My laptop freezes on `make reset`:**
- Don't use `reset-pci` / `reset-acpi`. The default `make reset` only does
  a module reload and is safe.

---

## Contributing

Bug reports welcome — please include:

- Kernel version (`uname -r`)
- Python version (`python3 --version`)
- pyroute2 version (`pacman -Qi python-pyroute2` or `pip show pyroute2`)
- Carrier and APN (you don't need to share the APN string; just "IPv4-only"
  vs "dual-stack" is useful)
- Full `journalctl -u xmm7360 -n 200` output
- `ip -br addr show wwan0`
- `dmesg | grep -iE 'xmm|iosm'`

PRs welcome too. Keep patches minimal, guard kernel-API changes with
`LINUX_VERSION_CODE`, and please test against at least one LTS kernel.

---

## Credits

- Upstream driver: [xmm7360/xmm7360-pci](https://github.com/xmm7360/xmm7360-pci)
- Original authors listed in the upstream `README.md`
- Kernel-API patches adapted from the linked community issue threads
  referenced in upstream PR discussions
