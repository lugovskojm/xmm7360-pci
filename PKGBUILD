# Maintainer: xmm7360 community <omarchy@local>
# PKGBUILD for ArchLinux / Omarchy
# Installs xmm7360-pci via DKMS so the module rebuilds automatically on
# kernel upgrades. Intended to be run in-tree: `cd xmm7360-pci && makepkg -si`.
pkgname=xmm7360-pci-dkms
_pkgbase=xmm7360-pci
pkgver=1.0.omarchy
pkgrel=8
pkgdesc="Intel XMM7360 / Fibocom L850-GL LTE modem driver (DKMS) — patched for kernel 6.6+ and ThinkPad X280"
arch=('x86_64')
url="https://github.com/xmm7360/xmm7360-pci"
license=('GPL2' 'BSD')
depends=('dkms' 'acpi_call-dkms' 'python' 'python-pyroute2')
makedepends=('git')
provides=('xmm7360-pci')
conflicts=('xmm7360-pci')
install=${pkgname}.install
backup=('etc/default/xmm7360')

# We build straight from the checked-out repo, so no source=() entries are
# needed. makepkg refuses directory entries in source=(); instead we copy
# everything from $startdir in package() below.
source=()
sha256sums=()

package() {
    local _src="${pkgname%-dkms}-${pkgver}"
    local _dkmsdir="${pkgdir}/usr/src/${_src}"
    local _sharedir="${pkgdir}/usr/share/${pkgname%-dkms}"

    # Kernel module sources (picked up by DKMS)
    install -dm755 "${_dkmsdir}"
    install -m644 "${startdir}/xmm7360.c" "${_dkmsdir}/"
    install -m644 "${startdir}/Makefile"  "${_dkmsdir}/"
    install -m644 "${startdir}/dkms.conf" "${_dkmsdir}/"

    # Userspace helpers — exclude __pycache__ (transient, causes file conflicts
    # across rebuilds since .pyc files aren't reproducible).
    install -dm755 "${_sharedir}"
    _copy_clean() {
        local src="$1" dst="$2"
        cp -a "$src" "$dst"
        find "$dst" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
        find "$dst" -type f -name '*.pyc'     -delete 2>/dev/null || true
    }
    _copy_clean "${startdir}/rpc"      "${_sharedir}/"
    _copy_clean "${startdir}/scripts"  "${_sharedir}/"
    _copy_clean "${startdir}/trace"    "${_sharedir}/"
    _copy_clean "${startdir}/examples" "${_sharedir}/"
    install -m644 "${startdir}/xmm7360.ini.sample" "${_sharedir}/"

    # Docs
    install -dm755 "${pkgdir}/usr/share/doc/${pkgname}"
    install -m644 "${startdir}/README.md"      "${pkgdir}/usr/share/doc/${pkgname}/"
    install -m644 "${startdir}/README.X280.md" "${pkgdir}/usr/share/doc/${pkgname}/"
    install -m644 "${startdir}/INSTALLING.md"  "${pkgdir}/usr/share/doc/${pkgname}/"
    install -m644 "${startdir}/DEVICES.md"     "${pkgdir}/usr/share/doc/${pkgname}/"

    # udev rule so NetworkManager/systemd-networkd pick up wwan0
    install -dm755 "${pkgdir}/usr/lib/udev/rules.d"
    cat > "${pkgdir}/usr/lib/udev/rules.d/80-xmm7360.rules" <<'EOF'
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="xmm7360", NAME="wwan0"
EOF

    # modprobe.d: blacklist iosm so xmm7360 wins the race
    install -dm755 "${pkgdir}/usr/lib/modprobe.d"
    cat > "${pkgdir}/usr/lib/modprobe.d/xmm7360.conf" <<'EOF'
# xmm7360 owns the XMM7360/L850-GL PCIe modem — keep iosm out of the way.
blacklist iosm
EOF

    # systemd service + helper scripts in /usr/lib/xmm7360-pci/
    install -dm755 "${pkgdir}/usr/lib/xmm7360-pci"
    install -m755 "${startdir}/scripts/xmm7360-up.sh"   "${pkgdir}/usr/lib/xmm7360-pci/xmm7360-up.sh"
    install -m755 "${startdir}/systemd/xmm7360-down.sh" "${pkgdir}/usr/lib/xmm7360-pci/xmm7360-down.sh"

    install -dm755 "${pkgdir}/usr/lib/systemd/system"
    install -m644 "${startdir}/systemd/xmm7360.service" "${pkgdir}/usr/lib/systemd/system/xmm7360.service"

    # Sensible default config (user edits this to set APN)
    install -dm755 "${pkgdir}/etc/default"
    cat > "${pkgdir}/etc/default/xmm7360" <<'EOF'
# APN for the LTE connection. Examples:
#   internet.mts.ru   — MTS (Russia)
#   internet.beeline.ru
#   internet.tele2.ru
#   internet
XMM7360_APN=internet
EOF

    # Persistent sysctl to keep rp_filter=0 across reboots (matching what
    # the xmm7360-up.sh script sets at runtime).
    install -dm755 "${pkgdir}/usr/lib/sysctl.d"
    cat > "${pkgdir}/usr/lib/sysctl.d/99-xmm7360.conf" <<'EOF'
# Raw-IP POINTOPOINT wwan0 plus a faster default route via wifi leaves the
# kernel's reverse-path filter rejecting return packets. Relax it.
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.wwan0.rp_filter = 0
EOF
}
