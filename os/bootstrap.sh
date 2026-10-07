#!/usr/bin/env bash
#
# NextDesk OS bootstrap - turns a fresh, minimal Debian 13 (trixie) install into NextDesk:
# installs Google Chrome, builds and installs the nextdesk-desktop package, and points it at
# the Nextcloud server. Needs root, amd64 and internet access. Reboot afterwards.
#
# One-liner (on the target machine):
#   curl -fsSL https://raw.githubusercontent.com/nexed-tech/nextdesk/main/os/bootstrap.sh | sudo bash -s -- --url https://cloud.example.com
#
# From a checkout, it builds from that checkout instead of downloading the repo:
#   sudo os/bootstrap.sh --url https://cloud.example.com

set -euo pipefail

REPO='nexed-tech/nextdesk'
CHROME_DEB='https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb'

URL=''
REF='main'

usage() {
    cat <<EOF
Usage: bootstrap.sh [--url URL] [--ref GIT_REF]

  --url URL      Nextcloud base URL (can also be set later with: nextdesk-config --url URL)
  --ref REF      Branch, tag or commit of $REPO to build from (default: main;
                 ignored when run from a checkout)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url) URL="${2:-}"; shift 2 ;;
        --ref) REF="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

info() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'Run as root (sudo).'
[ "$(dpkg --print-architecture)" = amd64 ] || die 'Google Chrome is only available for amd64.'
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || printf '\033[33mWarning: built for Debian 13 (trixie), this is %s.\033[0m\n' "${PRETTY_NAME:-unknown}" >&2

export DEBIAN_FRONTEND=noninteractive
work="$(mktemp -d)"
chmod 755 "$work"   # apt's sandbox user must be able to read the .deb files in it
trap 'rm -rf "$work"' EXIT

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

# Source: the checkout this script lives in, or a tarball of $REF from GitHub.
src=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [ -f "$candidate/os/package/build.sh" ] && src="$candidate"
fi
if [ -z "$src" ]; then
    info "Downloading $REPO ($REF)"
    mkdir -p "$work/src"
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$work/src" --strip-components=1
    src="$work/src"
fi

info 'Building nextdesk-desktop'
deb="$(bash "$src/os/package/build.sh" "$work")"
chmod 644 "$deb"

info 'Installing nextdesk-desktop and the desktop (this takes a while)'
apt-get install -y --no-install-recommends "$deb"

if [ -n "$URL" ]; then
    info "Pointing NextDesk at $URL"
    nextdesk-config --url "$URL"
fi

echo
printf '\033[32mNextDesk is installed. Reboot to get the login screen.\033[0m\n'
[ -n "$URL" ] || echo 'Set the Nextcloud server first with: nextdesk-config --url https://cloud.example.com'
