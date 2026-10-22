#!/usr/bin/env bash
# Installer driver Broadcom STA (wl) untuk BCM4360 / BCM43xx di IGOS Nusantara 2026 (basis AlmaLinux 10).
#
# Pemakaian:
#   sudo bash install-broadcom-wl.sh              # build untuk kernel yang sedang berjalan
#   sudo bash install-broadcom-wl.sh <versi-kernel>  # build untuk kernel lain (mis. setelah update, sebelum reboot)
#
# Jalankan ulang script ini setiap kali kernel di-update.

set -euo pipefail

KVER="${1:-$(uname -r)}"
ALMA_AS="https://repo.almalinux.org/almalinux/10/AppStream/x86_64/os/"
ALMA_KEY="https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux-10"
SRPM_DIRS=(
  "https://download1.rpmfusion.org/nonfree/fedora/updates/42/SRPMS/w/"
  "https://download1.rpmfusion.org/nonfree/fedora/releases/42/Everything/source/SRPMS/w/"
)

log()  { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m!!\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Jalankan dengan sudo: sudo bash $0"

if ! lspci -nn | grep -q '\[14e4:43'; then
  warn "Tidak ditemukan perangkat Wi-Fi Broadcom (14e4:43xx). Lanjut tetap..."
fi

DNF=/usr/bin/dnf5; [ -x "$DNF" ] || DNF=/usr/bin/dnf

# 1. Paket build. Mirror AppStream IGOS sering rusak, jadi compiler diambil dari AppStream AlmaLinux 10.
log "Memasang paket build untuk kernel $KVER ..."
"$DNF" -y --disablerepo='*' --enablerepo=baseos,ign \
  --repofrompath=alma10as,"$ALMA_AS" \
  --setopt=alma10as.gpgcheck=1 --setopt=alma10as.gpgkey="$ALMA_KEY" \
  install gcc make patch elfutils-libelf-devel "kernel-devel-$KVER"

KSRC="/lib/modules/$KVER/build"
[ -d "$KSRC" ] || KSRC="/usr/src/kernels/$KVER"
[ -f "$KSRC/Makefile" ] || die "Header kernel untuk $KVER tidak ditemukan."

# 2. Ambil source (tarball Broadcom + patch) dari SRPM RPM Fusion.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

SRPM_URL=""
for d in "${SRPM_DIRS[@]}"; do
  name="$(curl -fsSL "$d" | grep -o 'wl-kmod-[0-9][^"<]*\.src\.rpm' | sort -uV | tail -1 || true)"
  if [ -n "$name" ]; then SRPM_URL="$d$name"; break; fi
done
[ -n "$SRPM_URL" ] || die "Gagal menemukan SRPM wl-kmod di RPM Fusion."

log "Mengunduh $SRPM_URL ..."
mkdir dl src
curl -fsSL -o dl/wl-kmod.src.rpm "$SRPM_URL"
(cd src && rpm2cpio ../dl/wl-kmod.src.rpm | cpio -idm --quiet)

log "Mengekstrak dan menerapkan patch ..."
mkdir build
tar xzf src/hybrid-v35_64-nodebug-pcoem-*.tar.gz -C build
for p in src/wl-kmod-0*.patch; do
  patch -d build -p1 -s --no-backup-if-mismatch < "$p" || die "Patch gagal: $p"
done

# 3. Kernel IGOS/RHEL melaporkan versi 6.12 tapi stack wireless-nya di-backport dari kernel
#    yang lebih baru. Aktifkan cabang kode per fitur, berdasarkan header kernel yang sebenarnya.
enable_guard() {  # $1 = minor versi 6.x
  grep -rlE "KERNEL_VERSION\(6, $1, 0\)" build/src | xargs -r sed -i -E \
    "s/LINUX_VERSION_CODE >= KERNEL_VERSION\(6, $1, 0\)/1/g; s/LINUX_VERSION_CODE < KERNEL_VERSION\(6, $1, 0\)/0/g"
  log "  fitur kernel 6.$1 terdeteksi (backport)"
}
CFG="$KSRC/include/net/cfg80211.h"
[ -f "$KSRC/include/net/lib80211.h" ]                         || enable_guard 13
grep -A2 '(\*get_tx_power)' "$CFG"     | grep -q link_id       && enable_guard 14
grep -q 'timer_delete(' "$KSRC/include/linux/timer.h"          && enable_guard 15
grep -A1 '(\*set_wiphy_params)' "$CFG" | grep -q radio_idx     && enable_guard 17

# 4. Build. objtool dimatikan karena blob biner Broadcom tidak lolos pemeriksaannya.
log "Mengompilasi wl.ko ..."
make -C "$KSRC" M="$WORK/build" -j"$(nproc)" objtool-enabled= >build.log 2>&1 \
  || { tail -30 build.log; die "Build gagal (log di atas)."; }
[ -f build/wl.ko ] || die "wl.ko tidak terbentuk."

# 5. Pasang modul, blacklist driver yang bentrok, muat saat boot.
log "Memasang modul ..."
install -D -m 644 build/wl.ko "/lib/modules/$KVER/extra/wl/wl.ko"
cat > /etc/modprobe.d/broadcom-wl-blacklist.conf <<'EOF'
blacklist b43
blacklist b43legacy
blacklist bcma
blacklist ssb
blacklist brcmsmac
blacklist brcmfmac
blacklist bcm43xx
EOF
echo wl > /etc/modules-load.d/wl.conf
depmod -a "$KVER"

if [ "$KVER" = "$(uname -r)" ]; then
  if [ -d /sys/module/wl ]; then
    log "Modul wl sudah aktif; versi baru dipakai setelah reboot."
  else
    modprobe -r b43 bcma ssb brcmsmac 2>/dev/null || true
    modprobe wl && log "Modul wl dimuat."
  fi
else
  log "Modul untuk kernel $KVER terpasang; aktif setelah boot ke kernel tersebut."
fi

log "Selesai. Sambungkan Wi-Fi lewat menu jaringan atau: nmcli dev wifi connect <SSID> --ask"
