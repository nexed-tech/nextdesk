# NextDesk

Chromebook-style Nextcloud desktop: one command pre-registers Nextcloud apps as browser web
apps (PWAs: own window, custom name + icon, app menu / Start menu, taskbar) via the
`WebAppInstallForceList` browser policy. No build step, no runtime; it's two setup scripts
plus server-side config.

Production Nextcloud: https://files.nexed.tech (Nextcloud 35, AIO, SSO via `user_oidc`).

## Layout

| Path | What |
|---|---|
| `init/nextdesk-setup.ps1` | Windows (Edge). Writes `HKLM\SOFTWARE\Policies\Microsoft\Edge\WebAppInstallForceList` (JSON string). Self-elevates. Run via `irm … \| iex`. |
| `init/nextdesk-setup.sh` | Linux, Debian-based (Debian, Ubuntu, Zorin OS). Writes `<policy dir>/managed/nextdesk.json` for Chrome > Edge > Chromium (first found). Offers to install Chrome. Run via `curl … \| sudo bash -s -- --url …`. |
| `assets/icons/` | 512×512 PNG app icons. The browser downloads them straight from GitHub raw (`custom_icon.url`). |
| `server/pwa_suite-manifest.json` | Custom manifest pasted into pwa_suite's expert-mode field (per-app names/icons via the `apps` block). |
| `server/custom.css` | Nextcloud custom CSS (header layout and draggable title-bar strip for window-controls-overlay). |

## Things that must stay true

- **The app catalog exists twice.** `$Catalog` in the `.ps1` and `APP_PATH`/`APP_ICON` in
  the `.sh` must stay in sync, along with the default app list and the README tables.
  Nextcloud app ids differ from display names: Talk = `spreed`, Office = `/apps/office/documents`,
  Files = `/apps/files/files`.
- **Icon hashes are computed at install time.** The policy needs `custom_icon.hash` = SHA-256
  of the icon file, so both scripts download each icon and hash it. Changing an icon needs no
  script change, only a re-run.
- **Windows script must keep working under `irm | iex`.** Everything lives in the
  `Install-NextDesk` function and uses `return`, never `exit`, which would close the user's
  terminal. It must stay Windows PowerShell 5.1 compatible (`-UseBasicParsing`, TLS 1.2,
  `ConvertTo-Json -InputObject` for 1-element arrays).
- **Windows script merges, Linux script owns its file.** The `.ps1` keeps other entries in
  `WebAppInstallForceList` and recognises its own by `custom_icon.url` pointing at this repo.
  The `.sh` owns `nextdesk.json` outright; `--uninstall` deletes it.
- **`.sh` files need LF line endings** (`.gitattributes`). The script must run under
  `curl | sudo bash`, so it reads prompts from `/dev/tty`.

## Server dependency: pwa_suite fork

Browsers identify a PWA by its manifest `id`. Stock Nextcloud gives every app the same
manifest, so the browser merges all force-installed apps into one. This needs the
**`nexed-tech/pwa_suite`** fork (sibling folder `../pwa_suite`, upstream
`manuelbernalcarvajal/pwa_suite`, PRs #19 and #20):

- Each app gets `id`/`start_url` = `/apps/<app>/`. The app id is taken from Nextcloud's own
  `/apps/theming/manifest/<app>` URL, which pwa_suite intercepts. pwa_suite's HTML `<link>`
  rewrite (`manifest.json?app=`) doesn't fire on Nextcloud 35, so don't rely on it.
- The optional `"apps"` block in the custom manifest overrides name, icons and `start_url` per app.
- Install on AIO: copy into `custom_apps/pwa_suite` in the `nextcloud-aio-nextcloud`
  container, then `occ upgrade`. Delete the old folder first; a leftover app-store
  `signature.json` causes integrity errors.

## Browser behaviour (learned the hard way)

- **Installed app ids never change.** After a manifest or policy change that affects
  identity, run `-Uninstall`/`--uninstall`, restart the browser until the apps are gone, then
  install again.
- **Edge ignores `install_as_shortcut`**, so it's not used. `custom_name`/`custom_icon` do work.
- **Log in first.** If the browser installs while the user isn't logged in to Nextcloud
  (redirect to SSO), it creates placeholder apps without the manifest (no overlay, wrong ids
  for `/apps/files/files` and `/apps/office/documents`).
- **Debug** with `edge://web-app-internals` / `chrome://web-app-internals`: look at
  `manifest_id`, `is_placeholder`, `display_override` and the `DedupeInstallUrlsCommand`
  log entry (it shows which install URLs merged into one app).
- **Linux:** snap/flatpak browsers ignore `/etc` policies; Ubuntu's default Chromium is a
  snap. Desktop icons are off by default because GNOME/Zorin require "Allow Launching";
  apps are pinned to the dock instead by a login helper the script installs
  (`/etc/xdg/autostart/nextdesk-pin.desktop` → `/usr/local/lib/nextdesk/nextdesk-pin`,
  app names in `/etc/nextdesk/pin-apps`, pins once per user via `org.gnome.shell favorite-apps`).
- **Linux title bar:** Chrome on Wayland has no window-controls overlay (accepted limitation).

## Testing

- **GitHub raw caching:** `raw.githubusercontent.com` caches for 5 minutes and ignores query
  strings. To test a fresh push, use a commit-SHA URL:
  `https://raw.githubusercontent.com/nexed-tech/nextdesk/<sha>/init/nextdesk-setup.sh`.
- **`.ps1`:** parse-check with `[System.Management.Automation.Language.Parser]::ParseFile`
  under Windows PowerShell 5.1.
- **`.sh`:** `bash -n`, then run it as root in a Debian WSL/container with a fake
  `google-chrome-stable` on `PATH` (and a fake `gsettings` for the pin helper). Clean up
  `/etc/opt/chrome`, `/etc/nextdesk`, `/usr/local/lib/nextdesk` afterwards.
