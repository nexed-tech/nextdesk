#!/usr/bin/env bash
#
# Checks a built NextDesk ISO for things the installer needs, before a test install finds them:
# the image installs without "recommends", so tools that the installer stack only recommends
# (dosfstools, locales, ...) are easily missing.
#
#   sudo os/iso/check-image.sh dist/nextdesk-os-*.iso
#
# Lists recommended packages of the installer stack that aren't in the image (review: most are
# fine to skip, e.g. docs or modem support), and fails if a command an installer step calls is
# missing.

set -uo pipefail

iso="${1:?usage: check-image.sh ISO}"
[ "$(id -u)" -eq 0 ] || { echo 'Run as root (it mounts the image).' >&2; exit 1; }

mnt="$(mktemp -d)"
mkdir -p "$mnt/iso" "$mnt/sq"
cleanup() { umount "$mnt/sq" "$mnt/iso" 2>/dev/null; rm -rf "$mnt"; }
trap cleanup EXIT
mount -o loop,ro "$iso" "$mnt/iso" && mount -o loop,ro "$mnt/iso/live/filesystem.squashfs" "$mnt/sq" || exit 1
in_image() { chroot "$mnt/sq" dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

echo '== Recommended by the installer stack, not in the image (review)'
for p in calamares libkpmcore12 calamares-settings-debian live-boot live-config live-config-systemd \
         user-setup lightdm network-manager os-prober cryptsetup grub-common; do
    recs="$(chroot "$mnt/sq" dpkg-query -W -f='${Recommends}' "$p" 2>/dev/null)"
    echo "$recs" | tr ',' '\n' | sed 's/([^)]*)//g; s/^ *//; s/ *$//' | while read -r alt; do
        [ -n "$alt" ] || continue
        ok=0
        for a in $(echo "$alt" | tr '|' ' '); do in_image "$a" && ok=1; done
        [ "$ok" = 1 ] || echo "  $p: $alt"
    done
done

echo '== Commands the installer steps call'
failed=0
#   partition (FAT EFI partition, ext4, btrfs, swap, LUKS), unpackfs, locale, keyboard, hwclock,
#   initramfs, users. (GRUB isn't in the image: the installer installs it from the medium's pool.)
for cmd in mkfs.fat mkfs.ext4 mkfs.btrfs mkswap cryptsetup sfdisk rsync unsquashfs locale-gen \
           setupcon hwclock update-initramfs useradd chpasswd os-prober; do
    if chroot "$mnt/sq" sh -c "command -v $cmd" >/dev/null 2>&1; then
        printf '  %-18s ok\n' "$cmd"
    else
        printf '  %-18s MISSING\n' "$cmd"
        failed=1
    fi
done
exit "$failed"
