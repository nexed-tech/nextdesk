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
| First login | `nextdesk-session-init` sets the wallpaper on each monitor and, while no web apps exist yet, opens Chrome at Nextcloud so the user logs in (the apps install after that). |
| Chrome | `/opt/google/chrome/initial_preferences` (no first-run UI, custom frame) and a small policy file (`nextdesk-os.json`: no Chrome sign-in or sync, no promos). |

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

   To test a branch, add `--ref <branch or commit>`. The script is fetched from GitHub raw
   (5-minute cache), so use a commit SHA in both URLs when testing a fresh push.

On real hardware, add `spice-vdagent` (SPICE display) or `qemu-guest-agent` as needed. They
aren't dependencies.

## Build the package yourself

```sh
os/package/build.sh            # → dist/nextdesk-desktop_<version>_all.deb (needs dpkg-deb; WSL Debian works)
sudo apt install --no-install-recommends ./dist/nextdesk-desktop_*.deb
```

Use `--no-install-recommends`. Without it, apt pulls in Thunar and the rest of the Xfce
apps. Everything NextDesk needs is a hard dependency.

## Roadmap

1. **This package**: a desktop that works and looks right on a fresh netinst.
2. **ISO**: `live-build` + Calamares installer around the package.
3. **Multi-user + SSO**: OS login through Keycloak (PAM), with the browser already logged
   in to Nextcloud. This is where it ties into Lintune.
