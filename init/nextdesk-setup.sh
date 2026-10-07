#!/usr/bin/env bash
#
# NextDesk (Linux) - pre-registers Nextcloud apps as web apps (PWAs) in Google Chrome,
# Microsoft Edge or Chromium via the WebAppInstallForceList enterprise policy.
#
# Writes one policy file, <browser policy dir>/managed/nextdesk.json, with one entry per
# Nextcloud app, using a custom name and icon from the nextdesk GitHub repo. The browser
# installs the apps on its next start and creates the app-menu (.desktop) entries and
# desktop shortcuts itself.
#
# Built for Debian-based distros (Debian, Ubuntu, Zorin OS, ...). Needs root.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.sh | sudo bash -s -- --url https://cloud.example.com
# Remove again:
#   curl -fsSL https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.sh | sudo bash -s -- --uninstall

set -euo pipefail

ICON_BASE='https://raw.githubusercontent.com/nexed-tech/nextdesk/main/assets/icons'
POLICY_FILE='nextdesk.json'
CHROME_DEB='https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb'

# App name -> path on the Nextcloud server and icon file in assets/icons
# (keep in sync with $Catalog in nextdesk-setup.ps1)
declare -A APP_PATH=(
    [Calendar]='/apps/calendar/'        [Contacts]='/apps/contacts/'
    [Files]='/apps/files/files'         [Mail]='/apps/mail/'
    [Notes]='/apps/notes/'              [Office]='/apps/office/documents'
    [Photos]='/apps/photos/'            [Talk]='/apps/spreed/'
    [Tasks]='/apps/tasks/'              [Deck]='/apps/deck/'
    [Forms]='/apps/forms/'              [News]='/apps/news/'
)
declare -A APP_ICON=(
    [Calendar]='nextcloud-calendar.png' [Contacts]='nextcloud-contacts.png'
    [Files]='nextcloud-files.png'       [Mail]='nextcloud-mail.png'
    [Notes]='nextcloud-notes.png'       [Office]='nextcloud-office.png'
    [Photos]='nextcloud-photos.png'     [Talk]='nextcloud-talk.png'
    [Tasks]='nextcloud-tasks.png'       [Deck]='nextcloud-deck.png'
    [Forms]='nextcloud-forms.png'       [News]='nextcloud-news.png'
)
CATALOG_ORDER='Calendar Contacts Files Mail Notes Office Photos Talk Tasks Deck Forms News'

# Browser key -> policy directory and binaries to look for (native packages only)
declare -A POLICY_DIR=(
    [chrome]='/etc/opt/chrome/policies/managed'
    [edge]='/etc/opt/edge/policies/managed'
    [chromium]='/etc/chromium/policies/managed'
)
declare -A BROWSER_BINS=(
    [chrome]='google-chrome-stable google-chrome'
    [edge]='microsoft-edge-stable microsoft-edge'
    [chromium]='chromium'
)
declare -A BROWSER_NAME=([chrome]='Google Chrome' [edge]='Microsoft Edge' [chromium]='Chromium')
BROWSER_ORDER='chrome edge chromium'

# --- Options ----------------------------------------------------------------------------
URL="${NEXTDESK_URL:-}"
APPS='Calendar,Contacts,Files,Mail,Notes,Office,Photos,Talk,Tasks'
BROWSER=''
NAME_PREFIX=''
DESKTOP_SHORTCUT=true
UNINSTALL=false
INSTALL_CHROME=''   # '' = ask, yes, no

usage() {
    cat <<EOF
Usage: nextdesk-setup.sh [options]

  --url URL              Nextcloud base URL (prompted if omitted)
  --apps A,B,...         Apps to register (default: $APPS)
                         Available: ${CATALOG_ORDER// /, }
  --browser NAME         chrome, edge or chromium (default: first one found, in that order)
  --name-prefix TEXT     Prefix for app names, e.g. 'Nextcloud '
  --no-desktop-shortcut  Only create app-menu entries
  --install-chrome       Install Google Chrome without asking if no browser is found
  --no-install           Never install a browser
  --uninstall            Remove the NextDesk policy (the browser then removes the apps)
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url)                 URL="${2:-}"; shift 2 ;;
        --apps)                APPS="${2:-}"; shift 2 ;;
        --browser)             BROWSER="${2:-}"; shift 2 ;;
        --name-prefix)         NAME_PREFIX="${2:-}"; shift 2 ;;
        --no-desktop-shortcut) DESKTOP_SHORTCUT=false; shift ;;
        --install-chrome)      INSTALL_CHROME=yes; shift ;;
        --no-install)          INSTALL_CHROME=no; shift ;;
        --uninstall)           UNINSTALL=true; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# --- Helpers ----------------------------------------------------------------------------
info() { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

# Reads an answer from the terminal; works when the script itself arrives on stdin (curl | bash).
ask() {
    local prompt="$1" answer=''
    [ -r /dev/tty ] || return 1
    read -r -p "$prompt" answer < /dev/tty || return 1
    printf '%s' "$answer"
}

fetch() {  # fetch URL [OUTFILE]
    if command -v curl >/dev/null 2>&1; then
        if [ -n "${2:-}" ]; then curl -fsSL -o "$2" "$1"; else curl -fsSL "$1"; fi
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${2:--}" "$1"
    else
        die 'Neither curl nor wget is installed.'
    fi
}

json_str() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# Is there a native (non-snap, non-flatpak) install of this browser? Prints the binary.
find_browser() {
    local bin path
    for bin in ${BROWSER_BINS[$1]}; do
        path="$(command -v "$bin" 2>/dev/null)" || continue
        case "$path" in /snap/*) continue ;; esac   # /snap/bin/<name>
        path="$(readlink -f "$path")"
        case "$path" in /snap/*|*/bin/snap) continue ;; esac
        # Ubuntu's /usr/bin/chromium(-browser) can be a wrapper script that starts the snap
        if [ "$1" = chromium ] && grep -qs '/snap/' "$path"; then continue; fi
        printf '%s' "$path"
        return 0
    done
    return 1
}

[ "$(id -u)" -eq 0 ] || die 'Run as root, e.g.: curl -fsSL <script url> | sudo bash -s -- --url https://cloud.example.com'

# --- Uninstall --------------------------------------------------------------------------
if $UNINSTALL; then
    removed=0
    for b in $BROWSER_ORDER; do
        f="${POLICY_DIR[$b]}/$POLICY_FILE"
        if [ -f "$f" ]; then rm -f "$f"; info "Removed $f"; removed=$((removed + 1)); fi
    done
    if [ "$removed" -eq 0 ]; then
        info 'No NextDesk policy found.'
    else
        ok 'NextDesk policy removed. The browser uninstalls the apps (and their shortcuts) on its next start.'
    fi
    exit 0
fi

# --- Pick the browser -------------------------------------------------------------------
if [ -n "$BROWSER" ]; then
    [ -n "${POLICY_DIR[$BROWSER]:-}" ] || die "Unknown browser '$BROWSER'. Use chrome, edge or chromium."
    find_browser "$BROWSER" >/dev/null || die "${BROWSER_NAME[$BROWSER]} isn't installed (as a regular .deb package)."
else
    for b in $BROWSER_ORDER; do
        if find_browser "$b" >/dev/null; then BROWSER="$b"; break; fi
    done
fi

if [ -z "$BROWSER" ]; then
    # Snap/Flatpak browsers keep their own sandboxed policy location, so a file in /etc does nothing.
    if command -v snap >/dev/null 2>&1 && snap list chromium >/dev/null 2>&1; then
        warn 'Chromium is installed as a snap. Snap browsers ignore policies in /etc, so NextDesk cannot use it.'
    fi
    if command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -Eq 'com\.google\.Chrome|com\.microsoft\.Edge|org\.chromium\.Chromium'; then
        warn 'A Flatpak browser is installed. Flatpak browsers ignore policies in /etc, so NextDesk cannot use it.'
    fi
    info 'No supported browser found (Google Chrome, Microsoft Edge or Chromium as a regular package).'

    command -v apt-get >/dev/null 2>&1 || die 'Automatic install only works on Debian-based systems (apt). Install Google Chrome and run this again.'
    [ "$(dpkg --print-architecture)" = amd64 ] || die "Google Chrome is only available for amd64, this system is $(dpkg --print-architecture). On Debian, 'apt install chromium' works instead."

    if [ -z "$INSTALL_CHROME" ]; then
        answer="$(ask 'Install Google Chrome now? [Y/n] ')" || die 'No terminal to ask on. Run again with --install-chrome or --no-install.'
        case "$answer" in [Nn]*) INSTALL_CHROME=no ;; *) INSTALL_CHROME=yes ;; esac
    fi
    [ "$INSTALL_CHROME" = yes ] || die 'No browser to configure. Install Google Chrome and run this again.'

    info 'Installing Google Chrome...'
    deb="$(mktemp --suffix=.deb)"
    trap 'rm -f "$deb"' EXIT
    fetch "$CHROME_DEB" "$deb"
    chmod 644 "$deb"   # apt's sandbox user must be able to read it
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$deb" >/dev/null
    find_browser chrome >/dev/null || die 'Google Chrome install failed.'
    ok 'Google Chrome installed (Google'\''s package repo was added, so it updates with the system).'
    BROWSER=chrome
fi

info "Browser: ${BROWSER_NAME[$BROWSER]}"

# --- Nextcloud URL ----------------------------------------------------------------------
if [ -z "$URL" ]; then
    URL="$(ask 'Nextcloud URL (e.g. https://cloud.example.com): ')" || die 'No terminal to ask on. Pass --url.'
fi
URL="${URL%"${URL##*[![:space:]]}"}"; URL="${URL#"${URL%%[![:space:]]*}"}"   # trim
URL="${URL%/}"
[ -n "$URL" ] || die 'No Nextcloud URL given.'
case "$URL" in http://*|https://*) ;; *) URL="https://$URL" ;; esac

# --- Build the policy -------------------------------------------------------------------
entries=''
count=0
tmp="$(mktemp)"
trap 'rm -f "$tmp" "${deb:-}"' EXIT
IFS=',' read -r -a app_list <<< "$APPS"
for name in "${app_list[@]}"; do
    name="${name// /}"
    [ -n "$name" ] || continue
    [ -n "${APP_PATH[$name]:-}" ] || die "Unknown app '$name'. Available: ${CATALOG_ORDER// /, }"
    icon_url="$ICON_BASE/${APP_ICON[$name]}"
    # The policy requires the SHA-256 of the icon; compute it from the actual file.
    fetch "$icon_url" "$tmp" || die "Could not download $icon_url"
    hash="$(sha256sum "$tmp" | cut -d' ' -f1)"
    entry="{\"url\": $(json_str "$URL${APP_PATH[$name]}"), \"default_launch_container\": \"window\", \"create_desktop_shortcut\": $DESKTOP_SHORTCUT, \"custom_name\": $(json_str "$NAME_PREFIX$name"), \"custom_icon\": {\"url\": $(json_str "$icon_url"), \"hash\": \"$hash\"}}"
    entries="${entries:+$entries,
    }$entry"
    count=$((count + 1))
    printf '  + %-10s %s\n' "$name" "$URL${APP_PATH[$name]}"
done
[ -n "$entries" ] || die 'No apps selected.'

dir="${POLICY_DIR[$BROWSER]}"
mkdir -p "$dir"
printf '{\n  "WebAppInstallForceList": [\n    %s\n  ]\n}\n' "$entries" > "$dir/$POLICY_FILE"
chmod 644 "$dir/$POLICY_FILE"

# Chrome doesn't merge a list policy across files; warn if another file sets it too.
for f in "$dir"/*.json; do
    [ "$f" != "$dir/$POLICY_FILE" ] && grep -qs 'WebAppInstallForceList' "$f" &&
        warn "Note: $f also sets WebAppInstallForceList; only one of the two files will be used."
done

echo
ok "Registered $count NextDesk app(s) in $dir/$POLICY_FILE"
info "Restart ${BROWSER_NAME[$BROWSER]} and log in to $URL - the apps then appear in the app menu and on the desktop."
info "Check progress at chrome://policy and chrome://apps (edge://policy and edge://apps for Edge)."
