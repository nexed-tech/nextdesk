# NextDesk

Turns a PC into a Chromebook-style Nextcloud desktop: Nextcloud apps are pre-registered as
browser web apps (own window, custom name + icon, desktop and app-menu shortcuts) through the
`WebAppInstallForceList` browser policy. Windows uses Edge; Linux uses Chrome, Edge or Chromium.

## Server requirement

Browsers identify a PWA by its manifest `id`. Out of the box Nextcloud gives every app the
same manifest, so the browser merges them all into one app. The server needs
[pwa_suite](https://github.com/nexed-tech/pwa_suite) with the per-app manifest patch
(upstream PRs [#19](https://github.com/manuelbernalcarvajal/pwa_suite/pull/19) and
[#20](https://github.com/manuelbernalcarvajal/pwa_suite/pull/20)): every app gets
`id`/`start_url` = `/apps/<app>/`. The pwa_suite settings used with NextDesk are in
[`server/`](server/): `pwa_suite-manifest.json` (custom manifest) and `custom.css`.

## Windows

Run in PowerShell (it relaunches itself as administrator if needed):

```powershell
irm https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.ps1 | iex
```

With parameters:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.ps1))) -NextcloudUrl https://cloud.example.com
```

| Parameter | Default | |
|---|---|---|
| `-NextcloudUrl` | prompt (or `$env:NEXTDESK_URL`) | Nextcloud base URL |
| `-Apps` | Calendar, Contacts, Files, Mail, Notes, Office, Photos, Talk, Tasks | Also available: Deck, Forms, News |
| `-NamePrefix` | none | e.g. `'Nextcloud '` gives "Nextcloud Calendar" |
| `-NoDesktopShortcut` | off | Start menu entries only |
| `-NoLaunch` | off | Don't open Edge afterwards |
| `-Uninstall` | off | Remove all NextDesk apps |

Existing entries in `WebAppInstallForceList` that aren't from NextDesk are kept.
Edge installs the apps on its next policy refresh. Check `edge://policy` and `edge://apps`.

## Linux (Debian, Ubuntu, Zorin OS, …)

```bash
curl -fsSL https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.sh | sudo bash -s -- --url https://cloud.example.com
```

No curl? Use `wget -qO- <url> | sudo bash -s -- --url …` instead.

The script uses the first browser it finds: Google Chrome, then Microsoft Edge, then
Chromium. It must be a regular `.deb` install. Snap and Flatpak browsers ignore policies in
`/etc`, so they're skipped; note that Ubuntu's default Chromium is a snap. If no supported
browser is found, it offers to install Google Chrome (amd64; Google's apt repo is added so
Chrome updates with the system).

| Option | Default | |
|---|---|---|
| `--url URL` | prompt | Nextcloud base URL |
| `--apps A,B,…` | Calendar,Contacts,Files,Mail,Notes,Office,Photos,Talk,Tasks | Also available: Deck, Forms, News |
| `--browser NAME` | first found | `chrome`, `edge` or `chromium` |
| `--name-prefix TEXT` | none | e.g. `'Nextcloud '` |
| `--desktop-shortcut` | off | Also put icons on the desktop (GNOME/Zorin asks to "Allow Launching" them) |
| `--no-pin` | off | Don't pin the apps to the taskbar |
| `--install-chrome` / `--no-install` | ask | Install Chrome without asking / never |
| `--uninstall` | off | Remove the NextDesk policy |

The policy is written to `<browser policy dir>/managed/nextdesk.json`, e.g.
`/etc/opt/chrome/policies/managed/nextdesk.json`. Restart the browser and log in to
Nextcloud; the apps then appear in the app menu. Check `chrome://policy` and `chrome://apps`.
The same file allows notifications (`NotificationsAllowedForUrls`) and sound without a click first
(`AutoplayAllowlist`, so a Talk call rings) for the Nextcloud origin, so the apps don't each ask.

**Notifications while all apps are closed** need Web Push on the Nextcloud server (off by
default; two `occ` commands, see
[server/app/nextdesk/README.md](server/app/nextdesk/README.md#notifications-with-all-apps-closed-web-push)),
and the browser still running in the background. NextDesk OS
keeps Chrome running from login (see CLAUDE.md); on other desktops it's Chrome's own setting ("Continue
running background apps when Google Chrome is closed").

**Taskbar pinning (GNOME, Zorin OS, Ubuntu; Xfce with the docklike plugin):** the browser
creates the app launchers later, as the user, so the script installs a small login helper
(`/etc/xdg/autostart/nextdesk-pin.desktop`). It waits up to 15 minutes for the launchers,
adds them to the taskbar (GNOME: `org.gnome.shell favorite-apps`; Xfce: the docklike plugin's
pinned list, then restarts the panel) and exits. Each app is pinned once per user, so an app a
user unpins stays unpinned. When the script runs via `sudo` from the desktop, the helper also
starts right away, so restarting the browser is enough.

**Title bar:** to merge the Nextcloud header into the title bar (window-controls overlay) in
Chrome, turn off "Use system title bar and borders" in `chrome://settings/appearance`, then
click the ⌃ button next to the window controls in an app window.

## NextDesk OS

A ChromeOS-style Debian 13 desktop with these apps built in, its own installer ISO
([latest release](https://github.com/nexed-tech/nextdesk/releases/latest)), sign-in with Nextcloud
and central device policies: see [`os/README.md`](os/README.md),
[`policies/README.md`](policies/README.md) and the NextDesk Nextcloud app in
[`server/app/nextdesk/`](server/app/nextdesk/).

## Icons

Icons live in [`assets/icons/`](assets/icons/) and the browser loads them straight from this repo.
