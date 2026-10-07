#!/usr/bin/env bash
#
# Builds NextDesk's patched Debian packages ("backports"): Debian's own source package for
# the running release plus the patches in os/backports/<package>/, versioned
# <debian version>+nextdesk<N> so apt prefers them over Debian's build of the same version
# (and a newer Debian version wins again).
#
#   sudo os/backports/build.sh [OUTPUT_DIR]     (default: dist/ in the repo root)
#
# Runs on Debian 13 as root: enables deb-src, installs the build dependencies, builds.
# Bump NEXTDESK_REV when a patch changes.

set -euo pipefail

NEXTDESK_REV=1
PACKAGES='xfce4-docklike-plugin'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mkdir -p "${1:-$here/../../dist}" && cd "${1:-$here/../../dist}" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
# Source packages come from deb.debian.org through a temporary list (local mirrors often
# carry binaries only); the machine's own apt sources are left alone.
src_list=/etc/apt/sources.list.d/nextdesk-backports-src.sources
work="$(mktemp -d)"
chmod 755 "$work"   # apt downloads sources as the _apt user
trap 'rm -rf "$work"; rm -f "$src_list"; apt-get update -qq || true' EXIT
cat > "$src_list" <<SRC
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: $VERSION_CODENAME
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
apt-get update -qq
apt-get install -y -qq --no-install-recommends dpkg-dev devscripts quilt fakeroot >/dev/null
for pkg in $PACKAGES; do
    echo "==> $pkg"
    apt-get build-dep -y -qq "$pkg" >/dev/null
    (cd "$work" && apt-get source -qq "$pkg" >/dev/null)
    src="$(find "$work" -maxdepth 1 -type d -name "$pkg-*" | head -n 1)"
    mkdir -p "$src/debian/patches"
    for p in "$here/$pkg"/*.patch; do
        cp "$p" "$src/debian/patches/"
        echo "${p##*/}" >> "$src/debian/patches/series"
    done
    version="$(cd "$src" && dpkg-parsechangelog -S Version)+nextdesk$NEXTDESK_REV"
    (cd "$src" && DEBFULLNAME='NextDesk' DEBEMAIL='stephan@nexed.tech' \
        dch -b -v "$version" -D "$VERSION_CODENAME" "NextDesk build: $(cd "$here/$pkg" && ls *.patch | tr '\n' ' ')")
    (cd "$src" && dpkg-buildpackage -b -us -uc >/dev/null)
    find "$work" -maxdepth 1 -name "${pkg}_*+nextdesk*.deb" ! -name '*dbgsym*' -exec cp {} "$out/" \;
done
ls -1 "$out"/*+nextdesk*.deb
