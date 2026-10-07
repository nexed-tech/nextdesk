#!/usr/bin/env bash
#
# NextDesk OS bootstrap - turns a fresh, minimal Debian 13 (trixie) install into NextDesk:
# installs Google Chrome, adds the NextDesk apt repository, installs nextdesk-desktop and
# points it at the Nextcloud server. Needs root, amd64 and internet access. Reboot afterwards.
#
# One-liner (on the target machine):
#   curl -fsSL https://raw.githubusercontent.com/nexed-tech/nextdesk/main/os/bootstrap.sh | sudo bash -s -- --url https://cloud.example.com
#
# Run from a checkout, it builds nextdesk-desktop from that checkout instead of taking it from
# the repository (other packages, like the patched docklike, still come from the repository):
#   sudo os/bootstrap.sh --url https://cloud.example.com

set -euo pipefail

REPO_URL='https://repo.nexed.tech'
CHROME_DEB='https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb'
# Same paths as nextdesk-desktop ships; the bootstrap copies are removed once it's installed.
BOOT_KEYRING=/usr/share/keyrings/nextdesk-bootstrap.gpg
BOOT_SOURCES=/etc/apt/sources.list.d/nextdesk-bootstrap.sources

URL=''
APPS=''

usage() {
    cat <<EOF
Usage: bootstrap.sh [--url URL] [--apps A,B,...]

  --url URL      Nextcloud base URL (can also be set later with: nextdesk-config --url URL)
  --apps A,B     Nextcloud apps to install as web apps (default: nextdesk-setup's list)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url)  URL="${2:-}"; shift 2 ;;
        --apps) APPS="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

info() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'Run as root (sudo).'
[ "$(dpkg --print-architecture)" = amd64 ] || die 'Google Chrome is only available for amd64.'
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || die "NextDesk OS needs Debian 13 (trixie), this is ${PRETTY_NAME:-unknown}."

export DEBIAN_FRONTEND=noninteractive
work="$(mktemp -d)"
chmod 755 "$work"   # apt's sandbox user must be able to read the .deb files in it
cleanup() {
    rm -rf "$work"
    # Once nextdesk-desktop is in, its own repository entry and key take over.
    if [ -e /etc/apt/sources.list.d/nextdesk.sources ] && [ -e "$BOOT_SOURCES" ]; then
        rm -f "$BOOT_SOURCES" "$BOOT_KEYRING"
        apt-get update -qq || true
    fi
}
trap cleanup EXIT

info 'Installing prerequisites'
apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null

# Chrome's own package adds Google's apt repo, so it updates with the system afterwards.
if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
    info 'Installing Google Chrome'
    curl -fsSL -o "$work/chrome.deb" "$CHROME_DEB"
    chmod 644 "$work/chrome.deb"
    apt-get install -y -qq "$work/chrome.deb" >/dev/null
fi

if [ ! -e /etc/apt/sources.list.d/nextdesk.sources ]; then
    info "Adding the NextDesk repository ($REPO_URL)"
    curl -fsSL -o "$BOOT_KEYRING" "$REPO_URL/nextdesk-archive-keyring.gpg"
    chmod 644 "$BOOT_KEYRING"
    cat > "$BOOT_SOURCES" <<EOF
Types: deb
URIs: $REPO_URL/
Suites: trixie
Components: main
Signed-By: $BOOT_KEYRING
EOF
fi
apt-get update -qq

# From a checkout: build nextdesk-desktop from it (development). Otherwise from the repository.
pkg=nextdesk-desktop
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -f "$src/os/package/build.sh" ]; then
        info 'Building nextdesk-desktop from this checkout'
        pkg="$(bash "$src/os/package/build.sh" "$work")"
        chmod 644 "$pkg"
    fi
fi

info 'Installing NextDesk and the desktop (this takes a while)'
apt-get install -y --no-install-recommends "$pkg"

if [ -n "$URL" ] || [ -n "$APPS" ]; then
    info 'Configuring NextDesk'
    args=()
    [ -n "$URL" ] && args+=(--url "$URL")
    [ -n "$APPS" ] && args+=(--apps "$APPS")
    nextdesk-config "${args[@]}"
fi

echo
printf '\033[32mNextDesk is installed. Reboot to get the login screen.\033[0m\n'
[ -n "$URL" ] || [ -r /etc/nextdesk/nextdesk.conf ] ||
    echo 'Set the Nextcloud server first with: nextdesk-config --url https://cloud.example.com'
