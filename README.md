# NextDesk

Turns a Windows PC into a Chromebook-style Nextcloud desktop: Nextcloud apps are
pre-registered as Edge web apps (own window, custom name + icon, desktop and
Start menu shortcuts) through the `WebAppInstallForceList` Edge policy.

## Server requirement

Edge identifies a PWA by its manifest `id`. Out of the box Nextcloud gives every app the
same manifest, so Edge merges them all into one app. The server needs
[pwa_suite](https://github.com/manuelbernalcarvajal/pwa_suite) with the per-app manifest
patch: pages under `/apps/<app>/` link `manifest.json?app=<app>`, which returns
`id`/`start_url` = `/apps/<app>/`.

## Install

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
| `-Apps` | Calendar, Contacts, Mail, Notes, Office, Photos, Talk, Tasks | Also available: Deck, Forms, News |
| `-NamePrefix` | none | e.g. `'Nextcloud '` gives "Nextcloud Calendar" |
| `-NoDesktopShortcut` | off | Start menu entries only |
| `-NoLaunch` | off | Don't open Edge afterwards |
| `-Uninstall` | off | Remove all NextDesk apps |

Existing entries in `WebAppInstallForceList` that aren't from NextDesk are kept.
Edge installs the apps on its next policy refresh. Check `edge://policy` and `edge://apps`.

Icons live in [`assets/icons/`](assets/icons/) and Edge loads them straight from this repo.
