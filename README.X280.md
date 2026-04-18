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
sudo ./rpc/open_xdatachannel.py -a internet   # replace with your APN
# interface wwan0 should get an IPv4 address via DHCP
```

Or configure NetworkManager:

```sh
sudo nmcli connection add type gsm ifname wwan0 con-name mobile apn internet
sudo nmcli connection up mobile
```

## If it still fails

1. `dmesg | grep -E 'xmm7360|iosm'` — look for bind conflicts.
2. `lspci -vv -d 8086:7360` — confirm the modem is detected and the root
   port is not in D3.
3. `sudo make reset` — hard-resets the modem via `acpi_call`.
4. Compare your ACPI path: `grep -r 'PXSX' /sys/firmware/acpi/`.
