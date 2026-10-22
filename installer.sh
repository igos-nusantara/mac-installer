#!/bin/bash
# Download IGOS Nusantara ISO and make a UEFI (GPT + FAT32) bootable USB for Macs.
# Usage: ./installer.sh <disk>      e.g. ./installer.sh disk4
set -euo pipefail

URL="${URL:-https://repo.igos-nusantara.or.id/iso/2026/ign2026-live-mate-mini-beta5.iso}"
LABEL="${LABEL:-IGN26}"   # must match LABEL= in the ISO's grub.cfg
DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="$DIR/$(basename "$URL")"
DISK="${1:-}"

if [ -z "$DISK" ]; then
  diskutil list external physical
  echo "Usage: $0 <disk>   (e.g. $0 disk4)"; exit 1
fi
DISK="${DISK#/dev/}"

# 1. Download (resumable)
echo "==> Downloading $URL"
curl -fL -C - -A "Mozilla/5.0" -o "$ISO" "$URL"
file "$ISO" | grep -q "ISO 9660" || { echo "Not a valid ISO: $ISO"; exit 1; }

# 2. Safety: only external physical disks
diskutil list external physical | grep -q "^/dev/$DISK " \
  || { echo "/dev/$DISK is not an external physical disk"; exit 1; }
diskutil list "$DISK"
read -r -p "ALL DATA on /dev/$DISK will be erased. Type YES to continue: " ok
[ "$ok" = "YES" ] || { echo "Aborted."; exit 1; }

# 3. GPT + FAT32 (Mac firmware boots this from EFI/BOOT/BOOTX64.EFI)
echo "==> Formatting /dev/$DISK as GPT FAT32 ($LABEL)"
diskutil eraseDisk FAT32 "$LABEL" GPT "$DISK"
MNT="$(diskutil info "${DISK}s2" | awk -F': *' '/Mount Point/ {print $2}')"
[ -d "$MNT" ] || { echo "Partition ${DISK}s2 not mounted"; exit 1; }

# 4. Extract ISO contents (tar ignores the ISO's unreadable file modes)
echo "==> Copying files to $MNT"
tar -xf "$ISO" -C "$MNT" --no-same-owner --no-xattrs --no-mac-metadata

# 5. The ISO's UEFI grub.cfg ships installer args (inst.stage2=) instead of the
#    live-boot args used by isolinux.cfg -> boot falls into emergency mode.
for cfg in "$MNT/EFI/BOOT/grub.cfg" "$MNT/EFI/BOOT/BOOT.conf"; do
  [ -f "$cfg" ] && sed -i '' \
    "s|inst\.stage2=hd:LABEL=$LABEL|root=live:CDLABEL=$LABEL rd.live.image ro rd.luks=0 rd.md=0 rd.dm=0|g" "$cfg"
done
grep -q "root=live:CDLABEL=$LABEL" "$MNT/EFI/BOOT/grub.cfg" || { echo "grub.cfg patch failed"; exit 1; }

dot_clean -m "$MNT" 2>/dev/null || true
rm -rf "$MNT/.fseventsd" "$MNT/.Spotlight-V100"
[ -f "$MNT/EFI/BOOT/BOOTX64.EFI" ] && [ -f "$MNT/LiveOS/squashfs.img" ] \
  || { echo "Copy incomplete"; exit 1; }

sync
diskutil eject "$DISK"
echo "==> Done. Boot the Mac holding Option (⌥) and pick 'EFI Boot'."
