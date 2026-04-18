# Maintainer: xmm7360 community <omarchy@local>
# PKGBUILD for ArchLinux / Omarchy
# Installs xmm7360-pci via DKMS so the module rebuilds automatically on
# kernel upgrades.
pkgname=xmm7360-pci-dkms
pkgver=1.0.omarchy
pkgrel=1
pkgdesc="Intel XMM7360 / Fibocom L850-GL LTE modem driver (DKMS) — patched for kernel 6.6+ and ThinkPad X280"
arch=('x86_64')
url="https://github.com/xmm7360/xmm7360-pci"
license=('GPL2' 'BSD')
depends=('dkms' 'acpi_call-dkms' 'python' 'python-pyroute2')
makedepends=('git')
provides=('xmm7360-pci')
conflicts=('xmm7360-pci')
install=${pkgname}.install

source=("xmm7360.c"
        "Makefile"
        "dkms.conf"
        "rpc"
        "scripts"
        "trace"
        "examples"
        "INSTALLING.md"
        "README.md")
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

package() {
    install -dm755 "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}"
    cp -a "${srcdir}/xmm7360.c"  "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}/"
    cp -a "${srcdir}/Makefile"   "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}/"
    cp -a "${srcdir}/dkms.conf"  "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}/"

    # userspace helpers
    install -dm755 "${pkgdir}/usr/share/${pkgname%-dkms}"
    cp -a "${srcdir}/rpc"       "${pkgdir}/usr/share/${pkgname%-dkms}/"
    cp -a "${srcdir}/scripts"   "${pkgdir}/usr/share/${pkgname%-dkms}/"
    cp -a "${srcdir}/trace"     "${pkgdir}/usr/share/${pkgname%-dkms}/"
    cp -a "${srcdir}/examples"  "${pkgdir}/usr/share/${pkgname%-dkms}/"

    # docs
    install -dm755 "${pkgdir}/usr/share/doc/${pkgname}"
    install -m644 "${srcdir}/README.md"      "${pkgdir}/usr/share/doc/${pkgname}/"
    install -m644 "${srcdir}/INSTALLING.md"  "${pkgdir}/usr/share/doc/${pkgname}/"

    # udev rule so NetworkManager/systemd-networkd pick up wwan0
    install -Dm644 /dev/stdin "${pkgdir}/usr/lib/udev/rules.d/80-xmm7360.rules" <<'EOF'
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="xmm7360", NAME="wwan0"
EOF
}
