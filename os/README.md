# NextDesk OS

A ChromeOS-style desktop on Debian 13: a login screen, one bottom shelf with the Nextcloud
apps pinned, an app launcher and a system tray. No file manager, no local apps. The
Nextcloud apps are browser web apps (PWAs), installed through the same policy as the
`init/` scripts.

**X11 on purpose.** Chrome only draws the PWA title bar over the page (window-controls
overlay) on X11, not on Wayland. That rules out GNOME 49+ and Plasma 6.8+, which drop their
X11 sessions, so the desktop is **Xfce 4.20** (X11 for the long term), themed with Orchis,
Papirus and Inter.

## What's in the package

`nextdesk-desktop` is a meta-package: its dependencies pull in the desktop, and its files
set it up. It does this without touching any stock Xfce config files:

| Piece | How |
|---|---|
| Session | `NextDesk` session (`/usr/share/xsessions/nextdesk.desktop`) = `startxfce4`. LightDM + slick-greeter log into it by default. |
| Defaults | `/etc/xdg/nextdesk/` is put **in front of** `/etc/xdg` in `XDG_CONFIG_DIRS` (`/etc/X11/Xsession.d/60nextdesk` for the session, `/usr/lib/environment.d/60-nextdesk.conf` for D-Bus services such as xfconfd). It holds the panel layout, theme, window manager and session settings, and autostart. These are defaults: users can still change things. |
| Shelf | One 48px bottom panel: Whisker menu, docklike (pinned and running apps), tray, sound, power, notifications, clock. |
| Apps | `/usr/lib/nextdesk/nextdesk-setup` is `init/nextdesk-setup.sh`, copied in at build time. `nextdesk-config --url …` saves the server URL in `/etc/nextdesk/nextdesk.conf` and runs it. The pin helper pins the apps into docklike. |
| Wallpaper | `usr/share/nextdesk/wallpaper.svg`, also diverted over Xfce's built-in default `xfce-x.svg` (`preinst`). xfdesktop keys its wallpaper setting per monitor name, so replacing the default is what covers every monitor and user. |
| First login | `nextdesk-session-init`: while no web apps exist yet, opens Chrome at Nextcloud so the user logs in. |
| Chrome | `/opt/google/chrome/initial_preferences` (no first-run UI or EULA dialog, custom frame) and a small policy file (`nextdesk-os.json`: no Chrome sign-in or sync, no promos). Chrome's `chrome` binary is diverted to `chrome.nextdesk-real` and replaced by a wrapper that adds `--enable-features=DesktopPWAsWindowControlsOverlayWithNoToggle`: every web app draws its title bar over the page, without the per-app ⌃ toggle (off by default). There is no policy or `chrome://flags` entry for it. |

## Sign in with Nextcloud

The login screen is NextDesk's own LightDM greeter (`nextdesk-greeter`, Python/GTK). *Sign in with
Nextcloud* runs Nextcloud's Login Flow v2 in an embedded browser view (ephemeral: nothing is kept
between sign-ins), so the user signs in however the server does it (password, Entra ID / Keycloak
SSO, MFA). The resulting app password is passed to PAM, where `nextdesk-pam` (a `pam-auth-update`
profile, LightDM only) checks it with the NextDesk Nextcloud app (`server/app/nextdesk`):

- **First sign-in** creates the local account, named from the Nextcloud display name (first
  initial + last name: Stephan Craane → `scraane`; a number is added if taken). The link
  Nextcloud user ↔ account is in `/var/lib/nextdesk/users.json`; the app password in
  `/var/lib/nextdesk/users/<user>/` (root only).
- **Existing local accounts are never taken over.** Link one deliberately:
  `nextdesk-user link scraane stephan@nexed.tech` (`nextdesk-user list`, `unlink`).
- **Browser:** at session start the PAM helper gets a one-time login URL, which Chrome opens, so
  the user is signed in there too (lands on the server's default page).
- Local accounts (e.g. an admin) sign in under *Use a local account*.

**PIN (offline sign-in and unlocking).** After a Nextcloud sign-in the greeter asks for a PIN
(6–12 digits, can be skipped). Users with a PIN appear as tiles on the login screen, and the
lock screen goes straight to the PIN. Stored as a salted scrypt hash, root only.

- **Every PIN sign-in asks Nextcloud** whether the device's app password is still valid. Revoked
  (401: app password revoked, user disabled or deleted) → app password and PIN are deleted, the
  sign-in fails, and only a full Nextcloud sign-in gets in again. Server up (its public
  `status.php` answers) but the check doesn't confirm (slow, throttled, an error) → refused, nothing
  deleted: a revoked app password makes Nextcloud throttle its answers, so slow must not count as
  offline. Server not reachable (no network, down, maintenance) → allowed only within
  `offline_grace_days` (NextDesk policy, default 7) since the last successful check. 0 = PIN only
  works online.
- 5 wrong PINs remove the PIN.
- Nextcloud caches valid app passwords for 10 s (refreshed on every use), so a revocation takes
  effect after at most that long without use.

**Watchdog** (`nextdesk-watchdog.timer`, every 5 minutes, as root). For every user on the machine
who signs in with Nextcloud, logged in or not:

- **Remote wipe** (Nextcloud → Settings → Security → Devices → *Wipe device*): ends the user's
  sessions, deletes the local account and all its data, and reports the wipe to Nextcloud (which
  then removes the device).
- **Revoked** (401: device revoked, user disabled or deleted): ends the user's sessions, deletes
  the app password and PIN. The user's files stay; the login screen says why they were signed out.
- **Valid:** records the check (the offline grace period counts from it) and the current policy.
- **Unreachable or not confirming:** nothing. Losing the connection never logs anyone out.

## Install on a VM (Proxmox)

1. VM: 2 cores, 4 GB RAM, 16 GB disk, Display `VirtIO-GPU` or `Standard VGA`.
2. Install Debian 13 netinst. In the software selection, untick everything except
   *SSH server* and *standard system utilities*. Create a normal user: that's who logs in
   at the greeter.
3. As root (or with sudo):

   ```sh
   apt install -y curl
   curl -fsSL https://raw.githubusercontent.com/nexed-tech/nextdesk/main/os/bootstrap.sh | bash -s -- --url https://files.nexed.tech
   reboot
   ```

   Pick the apps your server actually has with `--apps`, e.g.
   `nextdesk-config --apps Calendar,Contacts,Files,Mail,Office,Photos`. The URL and the app
   list are saved in `/etc/nextdesk/nextdesk.conf` and kept on package upgrades. Apps that
   are dropped get unpinned at the next login.

   To test a branch, add `--ref <branch or commit>`. The script is fetched from GitHub raw
   (5-minute cache), so use a commit SHA in both URLs when testing a fresh push.

On real hardware, add `spice-vdagent` (SPICE display) or `qemu-guest-agent` as needed. They
aren't dependencies.

## apt repository

`https://repo.nexed.tech/` (GitHub Pages, `gh-pages` branch), suite `trixie`,
component `main`, signed with the NextDesk key (`os/apt/nextdesk-archive-keyring.asc`,
fingerprint `5E4F 49BD C4F8 07B0 BC80  F850 5048 7D9F 5924 D005`). `nextdesk-desktop` ships the
key and `/etc/apt/sources.list.d/nextdesk.sources`, so NextDesk updates with the system.

The `apt repository` workflow builds and publishes on every push to `main` that
touches `os/`: `nextdesk-desktop` plus the patched Debian packages in `os/backports/` (built in
a Debian 13 container). A version that's already published is never replaced, so bump
`Version:` in `os/package/DEBIAN/control` (or `NEXTDESK_REV` in `os/backports/build.sh`) to ship
a change. The private signing key is the `APT_SIGNING_KEY` repository secret.

## Build the package yourself

```sh
os/package/build.sh            # → dist/nextdesk-desktop_<version>_all.deb (needs dpkg-deb; WSL Debian works)
sudo apt install --no-install-recommends ./dist/nextdesk-desktop_*.deb
```

Use `--no-install-recommends`. Without it, apt pulls in Thunar and the rest of the Xfce
apps. Everything NextDesk needs is a hard dependency.

## Clone template (seal)

To turn an installed machine into a VM template, snapshot it, then run `os/seal.sh` on it
(like sysprep). It deletes the accounts you name (`--remove-user`; every account left ends up
in every clone), turns off LightDM autologin, purges test/build packages, points apt at
`deb.debian.org` (`--keep-mirror` to keep yours), resets the machine-id and SSH host keys (new
ones are made on first boot) and clears logs. `--clear-server` also removes the Nextcloud server
and app list, for templates that are set up per machine. Try it with `--dry-run` first.

```sh
sudo os/seal.sh --remove-user test --hostname nextdesk --poweroff
```

## Roadmap

1. **This package**: a desktop that works and looks right on a fresh netinst.
2. **ISO**: `live-build` + Calamares installer around the package; the installer asks for the
   Nextcloud URL and which apps to provision.
3. **Multi-user + SSO**: OS login through Keycloak (PAM), with the browser already logged
   in to Nextcloud. This is where it ties into Lintune.
