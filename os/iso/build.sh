#!/usr/bin/env bash
#
# Builds the NextDesk OS installer image (Debian 13, amd64, UEFI + BIOS, hybrid ISO).
#
#   sudo os/iso/build.sh [OUTPUT_DIR]       (default: dist/ in the repo root)
#
# Needs a Debian 13 host (or container) with live-build and apt-utils, as root, with internet access (it
# fetches Debian, repo.nexed.tech and Google Chrome). Takes a while: it builds a whole system.
#
# The image's file system is the finished NextDesk OS (nextdesk-desktop installed); the live
# session runs the NextDesk installer, which copies it to disk. Bootloaders, disk encryption
# and firmware are in a package pool on the medium, for installing offline.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$(mkdir -p "${1:-$repo/dist}" && cd "${1:-$repo/dist}" && pwd)"
version="$(sed -n 's/^Version: //p' "$repo/os/package/DEBIAN/control")"
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
command -v lb >/dev/null && command -v apt-ftparchive >/dev/null ||
    { echo 'Install the build tools first: apt install live-build apt-utils' >&2; exit 1; }

work="${NEXTDESK_ISO_WORK:-/var/tmp/nextdesk-iso}"
rm -rf "$work"
mkdir -p "$work"
cd "$work"

lb config \
    --distribution trixie \
    --archive-areas 'main contrib non-free-firmware' \
    --mirror-bootstrap http://deb.debian.org/debian \
    --mirror-chroot http://deb.debian.org/debian \
    --mirror-binary http://deb.debian.org/debian \
    --debootstrap-options '--include=ca-certificates' \
    --debian-installer none \
    --apt-recommends false \
    --linux-flavours amd64 \
    --firmware-chroot false \
    --firmware-binary false \
    --binary-images iso-hybrid \
    --bootloaders 'grub-efi,syslinux' \
    --uefi-secure-boot enable \
    --iso-application 'NextDesk OS' \
    --iso-volume 'NextDesk' \
    --iso-publisher 'nexed.tech' \
    --bootappend-live 'boot=live components quiet splash username=user hostname=nextdesk' \
    --bootappend-live-failsafe 'boot=live components username=user hostname=nextdesk nomodeset' \
    >/dev/null

cp -r "$here/config/." config/
# Google Chrome: Google's repo while building. Chrome's own package then adds its source
# (google-chrome.sources) to the system, so the build-time one has a different name.
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub > config/archives/google-chrome-build.key.chroot
echo 'deb [arch=amd64] https://dl.google.com/linux/chrome/deb/ stable main' > config/archives/google-chrome-build.list.chroot
# The firmware packages in the medium's pool, for the firmware index (chroot hook)
grep -E '^firmware-' "$here/config/package-lists/installer.list.binary" \
    > config/includes.chroot/usr/share/nextdesk-installer/firmware-packages
chmod 755 config/hooks/normal/*.hook.chroot
# nextdesk-desktop from this checkout (live-build installs .debs in packages.chroot/ into the
# image), so the ISO matches the source without waiting for the apt repository. It gets its own,
# higher version: repo.nexed.tech may already have this version as a different file, and apt then
# sees one of the two as a downgrade. The next published version is still higher than this.
mkdir -p config/packages.chroot
NEXTDESK_VERSION_SUFFIX="+iso$(date -u +%Y%m%d%H%M)" bash "$repo/os/package/build.sh" "$work/config/packages.chroot" >/dev/null
# BIOS GRUB for the medium's pool: it conflicts with grub-efi-amd64, so live-build can't resolve
# both from installer.list.binary; the binary hook 9100-nextdesk-pool adds these.
mkdir -p config/nextdesk-pool
(cd config/nextdesk-pool && apt-get download -qq grub-pc grub-pc-bin)
chmod 755 config/hooks/normal/*.hook.binary

lb build
built="$(ls "$work"/*.hybrid.iso 2>/dev/null | head -n 1)"
[ -n "$built" ] || { echo 'E: no ISO was built; see the log above' >&2; exit 1; }

iso="$out/nextdesk-os-${version}-amd64.iso"
mv "$built" "$iso"
(cd "$out" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
"$here/check-image.sh" "$iso" || { echo 'E: the image misses commands the installer needs (see above)' >&2; exit 1; }
echo "$iso"
