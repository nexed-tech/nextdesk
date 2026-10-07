#!/usr/bin/env bash
#
# NextDesk (Linux) - pre-registers Nextcloud apps as web apps (PWAs) in Google Chrome,
# Microsoft Edge or Chromium via the WebAppInstallForceList enterprise policy.
#
# Writes one policy file, <browser policy dir>/managed/nextdesk.json, with one entry per
# Nextcloud app, using a custom name and icon from the nextdesk GitHub repo. The browser
# installs the apps on its next start and creates the app-menu (.desktop) entries itself.
#
# On GNOME-based desktops (Zorin OS, Ubuntu, ...) and on Xfce with the docklike plugin
# (NextDesk OS, Zorin OS Lite) the apps are also pinned to the taskbar. The browser creates
# the launchers later, as the user, so a small login helper
# (/etc/xdg/autostart/nextdesk-pin.desktop) waits for them and pins each app once per user.
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
PIN_HELPER='/usr/local/lib/nextdesk/nextdesk-pin'
PIN_CONF='/etc/nextdesk/pin-apps'
PIN_AUTOSTART='/etc/xdg/autostart/nextdesk-pin.desktop'

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
DESKTOP_SHORTCUT=false   # GNOME/Zorin desktop icons need "Allow Launching" first, so off by default
PIN=true
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
  --desktop-shortcut     Also put icons on the desktop (GNOME/Zorin asks to "Allow Launching" them)
  --no-pin               Don't pin the apps to the taskbar
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
        --desktop-shortcut)    DESKTOP_SHORTCUT=true; shift ;;
        --no-pin)              PIN=false; shift ;;
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

# Installs the login helper that pins the apps to the taskbar (GNOME/Zorin: org.gnome.shell
# favorite-apps; Xfce: the docklike plugin) once the browser has created their launchers.
# Arguments: the app names.
install_pin_helper() {
    mkdir -p "${PIN_HELPER%/*}" "${PIN_CONF%/*}" "${PIN_AUTOSTART%/*}"
    printf '%s\n' "$@" > "$PIN_CONF"
    cat > "$PIN_HELPER" <<'HELPER'
#!/usr/bin/env bash
# NextDesk pin helper - runs at login, as the user. Pins the NextDesk web apps to the
# taskbar once the browser has created their launchers: the GNOME/Zorin dock or the Xfce
# docklike plugin. Each app is pinned only once per user, so an app the user unpins stays
# unpinned.
CONF=/etc/nextdesk/pin-apps
[ -r "$CONF" ] || exit 0

if command -v gsettings >/dev/null 2>&1 && gsettings get org.gnome.shell favorite-apps >/dev/null 2>&1; then
    desktop=gnome
elif command -v xfconf-query >/dev/null 2>&1 && command -v xfce4-panel >/dev/null 2>&1; then
    desktop=xfce
else
    exit 0   # no supported taskbar
fi

pin_gnome() {   # pin_gnome LAUNCHER.desktop
    local favs
    favs="$(gsettings get org.gnome.shell favorite-apps)"
    case "$favs" in
        *"'$1'"*) ;;
        '@as []'|'[]') gsettings set org.gnome.shell favorite-apps "['$1']" ;;
        *) gsettings set org.gnome.shell favorite-apps "${favs%]}, '$1']" ;;
    esac
}

# Panel plugin ids of the docklike plugins ("3" for /plugins/plugin-3).
docklike_ids() {
    xfconf-query -c xfce4-panel -p /plugins -lv 2>/dev/null |
        awk '$2 == "docklike" { sub("^/plugins/plugin-", "", $1); print $1 }'
}

# docklike keeps its pinned apps as desktop ids (launcher name without .desktop) in a
# keyfile, ~/.config/xfce4/panel/docklike-<plugin id>.rc. A new one starts from the
# system default (xfce4/panel/docklike.rc in XDG_CONFIG_DIRS), as the plugin itself does.
# Returns 1 while the panel has no docklike plugin yet.
xfce_changed=0
pin_xfce() {   # pin_xfce DESKTOP_ID
    local id="$1" plugin rc dir cur found=1
    for plugin in $(docklike_ids); do
        found=0
        rc="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/panel/docklike-$plugin.rc"
        if [ ! -f "$rc" ]; then
            mkdir -p "${rc%/*}"
            printf '[user]\n' > "$rc"
            IFS=: read -r -a dirs <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
            for dir in "${dirs[@]}"; do
                if [ -f "$dir/xfce4/panel/docklike.rc" ]; then cp "$dir/xfce4/panel/docklike.rc" "$rc"; break; fi
            done
        fi
        if grep -q '^pinned=' "$rc"; then
            cur="$(sed -n 's/^pinned=//p' "$rc" | head -n 1)"
            cur="${cur%;}"
            case ";$cur;" in *";$id;"*) continue ;; esac
            sed -i "s|^pinned=.*|pinned=${cur:+$cur;}$id;|" "$rc"
        elif grep -q '^\[user\]' "$rc"; then
            sed -i "/^\[user\]/a pinned=$id;" "$rc"
        else
            printf '[user]\npinned=%s;\n' "$id" >> "$rc"
        fi
        xfce_changed=1
    done
    return "$found"
}

# docklike only reads its config at startup, so the panel must restart to show new pins.
# `xfce4-panel --restart` makes the panel spawn a new copy and exit, which goes wrong now and
# then on a busy machine (seen right after login): the copy finds the old one still running
# and quits, leaving no panel, or the old one never restarts. The session manager doesn't
# bring a panel back either, so check for a new panel process and start one if needed.
panel_pid() { pgrep -n -u "$(id -u)" -x xfce4-panel; }
restart_panel() {
    local old new i
    old="$(panel_pid)"
    xfce4-panel --restart >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        new="$(panel_pid)"
        [ -n "$new" ] && [ "$new" != "$old" ] && return 0
    done
    [ -n "$new" ] && { kill "$new" 2>/dev/null; sleep 1; }   # the old panel never restarted
    setsid xfce4-panel >/dev/null 2>&1 < /dev/null &
}

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/nextdesk-pin.lock"
flock -n 9 || exit 0   # already running for this user

state="${XDG_STATE_HOME:-$HOME/.local/state}/nextdesk/pinned"
apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "${state%/*}" && touch "$state"

has_launcher() {   # has_launcher NAME: does the browser still have a web app launcher with this name?
    local f
    for f in "$apps_dir"/*.desktop; do
        [ -f "$f" ] && grep -qxF -- "Name=$1" "$f" && grep -q -- '--app-id=' "$f" && return 0
    done
    return 1
}

# Clean up after web apps the browser has removed (an app dropped from the policy, or reinstalled
# under a new id): unpin launchers that no longer exist, so they don't linger as blank icons, and
# forget the app in $state, so it's pinned again if it comes back. Only web app launchers
# (chrome-*/msedge-*) are touched; an app the user unpinned while its launcher exists stays unpinned.
gone() { case "$1" in chrome-*|msedge-*) [ ! -e "$apps_dir/$1.desktop" ] ;; *) return 1 ;; esac; }
if [ -s "$state" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] && has_launcher "$name" && printf '%s\n' "$name"
    done < "$state" > "$state.new"
    mv "$state.new" "$state"
fi
case "$desktop" in
    gnome)
        favs="$(gsettings get org.gnome.shell favorite-apps)"
        kept=''
        for item in $(printf '%s' "$favs" | tr -d "[]',@" | sed 's/^as //'); do
            gone "${item%.desktop}" || kept="${kept:+$kept, }'$item'"
        done
        [ "[$kept]" = "$favs" ] || gsettings set org.gnome.shell favorite-apps "[$kept]"
        ;;
    xfce)
        for plugin in $(docklike_ids); do
            rc="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/panel/docklike-$plugin.rc"
            cur="$(sed -n 's/^pinned=//p' "$rc" 2>/dev/null | head -n 1)"
            [ -n "$cur" ] || continue
            new=''
            IFS=';' read -r -a ids <<< "$cur"
            for id in "${ids[@]}"; do
                [ -n "$id" ] && ! gone "$id" && new="$new$id;"
            done
            if [ "$new" != "$cur" ]; then
                sed -i "s|^pinned=.*|pinned=$new|" "$rc"
                xfce_changed=1
            fi
        done
        ;;
esac
[ "$xfce_changed" -eq 1 ] && { restart_panel; xfce_changed=0; }

deadline=$((SECONDS + 900))   # the browser installs the apps on its next start; wait up to 15 min
while :; do
    pending=0
    pinned_before="$(wc -l < "$state")"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        grep -qxF -- "$name" "$state" && continue
        launcher=''
        for f in "$apps_dir"/*.desktop; do
            [ -f "$f" ] || continue
            if grep -qxF -- "Name=$name" "$f" && grep -q -- '--app-id=' "$f"; then
                launcher="${f##*/}"
                break
            fi
        done
        if [ -z "$launcher" ]; then pending=1; continue; fi
        case "$desktop" in
            gnome) pin_gnome "$launcher" ;;
            xfce)  pin_xfce "${launcher%.desktop}" || { pending=1; continue; } ;;
        esac
        printf '%s\n' "$name" >> "$state"
    done < "$CONF"
    # Restart the panel once the pins settle (all done, or no new launchers this round):
    # one restart instead of one per round.
    if [ "$xfce_changed" -eq 1 ] && { [ "$pending" -eq 0 ] || [ "$pinned_before" = "$(wc -l < "$state")" ]; }; then
        restart_panel
        xfce_changed=0
    fi
    [ "$pending" -eq 0 ] && exit 0
    [ "$SECONDS" -ge "$deadline" ] && exit 0
    sleep 5
done
HELPER
    chmod 755 "$PIN_HELPER"
    cat > "$PIN_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=NextDesk taskbar pins
Exec=$PIN_HELPER
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

    # Also start it right away for the user who ran sudo, so no new login is needed.
    local user="${SUDO_USER:-}" uid home
    [ -n "$user" ] && [ "$user" != root ] || return 0
    uid="$(id -u "$user")"
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -S "/run/user/$uid/bus" ] || return 0
    sudo -u "$user" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        setsid -f "$PIN_HELPER" >/dev/null 2>&1 < /dev/null || true
}

remove_pin_helper() {
    local f found=0
    for f in "$PIN_AUTOSTART" "$PIN_HELPER" "$PIN_CONF"; do
        [ -e "$f" ] && { rm -f "$f"; found=1; }
    done
    rmdir "${PIN_HELPER%/*}" "${PIN_CONF%/*}" 2>/dev/null || true
    [ "$found" -eq 1 ] && info 'Removed the taskbar pin helper.'
    return 0
}

[ "$(id -u)" -eq 0 ] || die 'Run as root, e.g.: curl -fsSL <script url> | sudo bash -s -- --url https://cloud.example.com'

# --- Uninstall --------------------------------------------------------------------------
if $UNINSTALL; then
    removed=0
    for b in $BROWSER_ORDER; do
        f="${POLICY_DIR[$b]}/$POLICY_FILE"
        if [ -f "$f" ]; then rm -f "$f"; info "Removed $f"; removed=$((removed + 1)); fi
    done
    remove_pin_helper
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

# The browser installs the apps right away, usually before anyone has logged in to
# Nextcloud. The app pages then redirect to the login, which gives placeholder apps (no
# manifest, wrong id), so install from pwa_suite's public install page when the server has it.
INSTALL_BASE=''
if page="$(fetch "$URL/apps/pwa_suite/install/files" 2>/dev/null)" && [[ "$page" == *'rel="manifest"'* ]]; then
    INSTALL_BASE="$URL/apps/pwa_suite/install"
else
    warn "The server has no pwa_suite install pages (/apps/pwa_suite/install/<app>); using the app pages. Log in to Nextcloud in the browser before it installs the apps."
fi

app_url() {   # app_url NAME -> URL the browser installs the app from
    local path="${APP_PATH[$1]}" id
    if [ -n "$INSTALL_BASE" ]; then
        id="${path#/apps/}"
        printf '%s/%s' "$INSTALL_BASE" "${id%%/*}"
    else
        printf '%s%s' "$URL" "$path"
    fi
}

# --- Build the policy -------------------------------------------------------------------
entries=''
count=0
pin_names=()
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
    entry="{\"url\": $(json_str "$(app_url "$name")"), \"default_launch_container\": \"window\", \"create_desktop_shortcut\": $DESKTOP_SHORTCUT, \"custom_name\": $(json_str "$NAME_PREFIX$name"), \"custom_icon\": {\"url\": $(json_str "$icon_url"), \"hash\": \"$hash\"}}"
    entries="${entries:+$entries,
    }$entry"
    count=$((count + 1))
    pin_names+=("$NAME_PREFIX$name")
    printf '  + %-10s %s\n' "$name" "$(app_url "$name")"
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

if $PIN; then install_pin_helper "${pin_names[@]}"; else remove_pin_helper; fi

echo
ok "Registered $count NextDesk app(s) in $dir/$POLICY_FILE"
where='the app menu'
$PIN && where="$where and on the taskbar"
$DESKTOP_SHORTCUT && where="$where and on the desktop"
info "Restart ${BROWSER_NAME[$BROWSER]} and log in to $URL - the apps then appear in $where."
info "Check progress at chrome://policy and chrome://apps (edge://policy and edge://apps for Edge)."
