#!/usr/bin/env bash
#
# Builds the nextdesk-desktop .deb from os/package/ (DEBIAN/ + root/) plus the shared setup
# script init/nextdesk-setup.sh, which goes in as /usr/lib/nextdesk/nextdesk-setup.
#
#   os/package/build.sh [OUTPUT_DIR]      (default: dist/ in the repo root)
#
# Needs dpkg-deb, so run it on Debian/Ubuntu (or WSL). File modes are set here, not taken
# from git, so a checkout made on Windows builds the same package.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${1:-$repo/dist}"
# NEXTDESK_VERSION_SUFFIX (e.g. "+iso202610081030") marks a build that isn't the published package
# (the ISO builds its own from the checkout): a different file needs a different version for apt.
version="$(sed -n 's/^Version: //p' "$here/DEBIAN/control")${NEXTDESK_VERSION_SUFFIX:-}"
deb="$out/nextdesk-desktop_${version}_all.deb"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp -r "$here/root/." "$stage/"
find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
install -D -m 755 "$repo/init/nextdesk-setup.sh" "$stage/usr/lib/nextdesk/nextdesk-setup"
# Xfce's default wallpaper, diverted in preinst (a symlink, so it's made here: git on Windows
# doesn't do symlinks).
mkdir -p "$stage/usr/share/backgrounds/xfce"
ln -s ../../nextdesk/wallpaper.svg "$stage/usr/share/backgrounds/xfce/xfce-x.svg"
mkdir -p "$stage/DEBIAN"
cp "$here"/DEBIAN/{control,preinst,postinst,prerm,postrm} "$stage/DEBIAN/"
sed -i "s/^Version: .*/Version: $version/" "$stage/DEBIAN/control"

# Everything under /etc is a conffile, so local edits survive package upgrades.
(cd "$stage" && find etc -type f | sed 's|^|/|' | sort) > "$stage/DEBIAN/conffiles"

find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod 755 "$stage"/DEBIAN/{preinst,postinst,prerm,postrm} \
    "$stage/usr/sbin/nextdesk-config" \
    "$stage/usr/lib/nextdesk/nextdesk-setup" \
    "$stage/usr/lib/nextdesk/nextdesk-session-init" \
    "$stage/usr/lib/nextdesk/nextdesk-pam" \
    "$stage/usr/lib/nextdesk/nextdesk-greeter" \
    "$stage/usr/lib/nextdesk/nextdesk-watchdog" \
    "$stage/usr/lib/nextdesk/nextdesk-policy" \
    "$stage/usr/sbin/nextdesk-user" \
    "$stage/usr/sbin/nextdesk-recovery-key" \
    "$stage/opt/google/chrome/chrome"

mkdir -p "$out"
dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
echo "$deb"
