#!/usr/bin/env bash
#
# NextDesk OS seal - prepares an installed NextDesk machine to be cloned as a template
# (like sysprep): removes accounts and test leftovers, resets the machine's identity and
# points apt at the public Debian mirror. Run as root on the machine (or a copy of it) right
# before shutting it down and converting it. Snapshot first: this can't be undone.
#
#   sudo os/seal.sh --remove-user alice --remove-user test --hostname nextdesk --poweroff
#   sudo os/seal.sh --dry-run ...          only print what it would do
#
# The machine boots afterwards with a new machine-id and new SSH host keys.

set -euo pipefail

DEBIAN_MIRROR='http://deb.debian.org/debian'
# Packages that are only for testing or building on a NextDesk machine; purged if installed.
DEV_PACKAGES='scrot php-cli podman hostapd build-essential devscripts dpkg-dev quilt fakeroot'

DRY_RUN=false
KEEP_MIRROR=false
CLEAR_SERVER=false
POWEROFF=false
HOSTNAME_NEW=''
REMOVE_USERS=()

usage() {
    cat <<EOF
Usage: seal.sh [options]

  --remove-user USER   Delete this account and its home (repeat for more). Every account
                       left on the machine ends up in every clone.
  --hostname NAME      Set the hostname (clones share it; rename them afterwards)
  --keep-mirror        Keep the current apt sources (default: switch to $DEBIAN_MIRROR)
  --clear-server       Remove the Nextcloud server and app list (/etc/nextdesk/nextdesk.conf)
                       and the browser policy, for a template that's set up per machine
  --poweroff           Power off when done
  --dry-run            Only print what would be done
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --remove-user)  REMOVE_USERS+=("${2:?--remove-user needs a name}"); shift 2 ;;
        --hostname)     HOSTNAME_NEW="${2:?--hostname needs a name}"; shift 2 ;;
        --keep-mirror)  KEEP_MIRROR=true; shift ;;
        --clear-server) CLEAR_SERVER=true; shift ;;
        --poweroff)     POWEROFF=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

info() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
run()  { if $DRY_RUN; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] || die 'Run as root.'
. /etc/os-release

# --- Accounts -------------------------------------------------------------------------------
for user in "${REMOVE_USERS[@]}"; do
    getent passwd "$user" >/dev/null || die "No such user: $user"
    [ "$user" != root ] || die 'Not removing root.'
done
if [ -n "${SUDO_USER:-}" ] && printf '%s\n' "${REMOVE_USERS[@]}" | grep -qxF -- "$SUDO_USER"; then
    warn "Removing $SUDO_USER, who is running this through sudo: that happens last, and ends this login."
fi

info 'Autologin and root SSH keys'
left="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }')"
for user in "${REMOVE_USERS[@]}"; do left="$(printf '%s\n' "$left" | grep -vxF -- "$user" || true)"; done
[ -z "$left" ] || warn "Accounts that stay (and end up in every clone): $(echo $left)"

# LightDM autologin (a test setup) would log every clone into that account.
for f in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [ -f "$f" ] && grep -q '^autologin-user=' "$f" || continue
    case "$f" in
        */lightdm.conf.d/*) run rm -f "$f" ;;
        *) run sed -i 's/^autologin-user=/#autologin-user=/' "$f" ;;
    esac
done
run gpasswd -M '' autologin 2>/dev/null || true
run rm -f /root/.ssh/authorized_keys

# --- Packages -------------------------------------------------------------------------------
info 'Packages'
installed=()
for p in $DEV_PACKAGES; do dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p"); done
if [ "${#installed[@]}" -gt 0 ]; then
    run apt-get purge -y -qq "${installed[@]}"
fi
run apt-get autoremove --purge -y -qq

if ! $KEEP_MIRROR; then
    info "apt sources -> $DEBIAN_MIRROR"
    if $DRY_RUN; then
        echo "    would write /etc/apt/sources.list.d/debian.sources and empty /etc/apt/sources.list"
    else
        [ -s /etc/apt/sources.list ] && cp /etc/apt/sources.list /etc/apt/sources.list.pre-seal
        printf '# See /etc/apt/sources.list.d/debian.sources\n' > /etc/apt/sources.list
        cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $VERSION_CODENAME $VERSION_CODENAME-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $VERSION_CODENAME-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        apt-get update -qq
    fi
fi
run apt-get clean

# --- NextDesk -------------------------------------------------------------------------------
if $CLEAR_SERVER; then
    info 'NextDesk server settings'
    run /usr/lib/nextdesk/nextdesk-setup --uninstall
    run rm -f /etc/nextdesk/nextdesk.conf
fi

# --- Machine identity -----------------------------------------------------------------------
info 'Machine identity'
# An empty machine-id makes systemd generate a new one on the next boot.
run truncate -s 0 /etc/machine-id
run rm -f /var/lib/dbus/machine-id
run ln -sf /etc/machine-id /var/lib/dbus/machine-id
# Debian doesn't make SSH host keys at boot, so add a unit that does when they're missing.
if [ -d /etc/ssh ]; then
    if $DRY_RUN; then
        echo '    would install nextdesk-ssh-host-keys.service and remove /etc/ssh/ssh_host_*'
    else
        cat > /etc/systemd/system/nextdesk-ssh-host-keys.service <<'EOF'
[Unit]
Description=Generate SSH host keys (NextDesk template clone)
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable --quiet nextdesk-ssh-host-keys.service
        rm -f /etc/ssh/ssh_host_*
    fi
fi
if [ -n "$HOSTNAME_NEW" ]; then
    run hostnamectl set-hostname "$HOSTNAME_NEW"
    run sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts
fi
run rm -f /var/lib/systemd/random-seed /var/lib/dhcp/*.leases /var/lib/NetworkManager/*.lease

# --- Logs and temporary files ---------------------------------------------------------------
info 'Logs and temporary files'
run journalctl --rotate --quiet
run journalctl --vacuum-time=1s --quiet
run find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
run find /var/log -type f -exec truncate -s 0 {} +
run find /tmp /var/tmp -mindepth 1 -delete
run rm -f /root/.bash_history /root/.lesshst /root/.wget-hsts

# --- Remove accounts (last: removing the account running sudo ends its login) ---------------
if [ "${#REMOVE_USERS[@]}" -gt 0 ]; then
    info "Removing accounts: ${REMOVE_USERS[*]}"
    trap '' HUP   # keep going when the login of the account being removed goes away
    for user in "${REMOVE_USERS[@]}"; do
        run loginctl terminate-user "$user" 2>/dev/null || true
        run pkill -KILL -u "$user" || true
        run deluser --quiet --remove-home "$user"
        run rm -f "/var/lib/AccountsService/users/$user"
        # Its Nextcloud link and stored app password
        [ -x /usr/sbin/nextdesk-user ] && run /usr/sbin/nextdesk-user unlink "$user" >/dev/null
    done
fi

echo
if $DRY_RUN; then
    info 'Dry run: nothing was changed.'
    exit 0
fi
info 'Sealed. Shut down now and convert the machine to a template; don'"'"'t boot it again first.'
if $POWEROFF; then
    systemctl poweroff
fi
