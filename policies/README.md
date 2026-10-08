# Device policies

One file per group of NextDesk machines (`<name>.yaml`). On every push to `main`, the apt repository
workflow checks each file, signs it with the repository key and publishes it to
`https://repo.nexed.tech/policy/<name>.json` (+ `.asc`). An invalid file fails the workflow and is
never published. The repository is public: no secrets in here.

A machine uses a policy when its `/etc/nextdesk/nextdesk.conf` has its URL:

```sh
sudo nextdesk-config --policy-url https://repo.nexed.tech/policy/nexed.json
sudo /usr/lib/nextdesk/nextdesk-policy --status
```

Machines check every 15 minutes (and at boot), verify the signature with the NextDesk keyring they
already have, and only apply a newer version (the serial is the file's commit time; don't add
one). A broken or unreachable policy never changes a machine: it keeps the last good one.

`index.yaml` maps a Nextcloud URL to a policy, for the installer.

## Keys

```yaml
nextcloud:
  url: https://cloud.example.com     # the server; a change applies when nobody is signed in
                                     # (at the latest at the next sign-in; users sign in again)
  apps: [Calendar, Files, Mail]      # Calendar Contacts Files Mail Notes Office Photos Talk Tasks
                                     # Deck Forms News; applied at once
updates:
  automatic: true                    # unattended-upgrades: Debian, security, NextDesk, Chrome
  time: "03:00"                      # daily (+ up to 30 min random); default 03:00
  reboot_at: "04:00"                 # optional: reboot when an update needs it (new kernel),
                                     # only with nobody signed in
packages:                            # http is fine here: apt checks the package signatures
  debian: http://mirror.lan/debian   # replaces deb.debian.org (also Debian lines in the old
                                     # /etc/apt/sources.list, commented out with a marker)
  security: http://mirror.lan/debian-security   # default security.debian.org
  proxy: http://apt-cacher.lan:3142  # apt proxy (apt-cacher-ng)
                                     # removed from the policy: back to Debian's defaults

# Coming next (accepted already, not applied yet):
url_change:                          # make a server change happen sooner: a forced logout
  logout_at: "2026-10-12 18:00"      # local time, once
  warn_minutes: 15
session:
  logout_at: "00:00"                 # daily logout (shared machines)
  warn_minutes: 10
screen_lock:
  after_minutes: 10                  # 0 = never
  on_suspend: true
  enforced: true                     # users can't change it
wallpaper:
  url: https://example.com/wallpaper.jpg
  sha256: <64 hex characters>
```
