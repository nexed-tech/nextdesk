# Device policies

One file per group of NextDesk machines (`<name>.yaml`). On every push to `main`, the apt repository
workflow checks each file, signs it with the repository key and publishes it to
`https://repo.nexed.tech/policy/<name>.json` (+ `.asc`). An invalid file fails the workflow and is
never published. The repository is public: no secrets in here.

**Which policy a machine uses:** the URL the Nextcloud admin sets for the server, in the NextDesk
app (Administration settings → Security → NextDesk → Device policy). The installer reads it, and
machines follow a change within 15 minutes. One URL per Nextcloud, for all its machines. Without
it, the installer looks the Nextcloud URL up in `index.yaml` here.

**Per hostname group** (checkbox next to that URL): a machine first takes the policy named after
the part of its computer name before the first `-`, next to the main one: with
`…/policy/nexed.json` as the URL, `sales-001` gets `…/policy/sales.json` (so add
`policies/sales.yaml` here). No `-` in the name, or no such file: the main policy. A renamed
machine moves to its new group within 15 minutes. The **Departments** listed in the NextDesk app
show up in the installer, which then proposes `<department>-<6 hex digits of the MAC>` as the name.

By hand, a machine's `/etc/nextdesk/nextdesk.conf` holds its URL:

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
  nextdesk: http://mirror.lan/nextdesk   # a mirror of repo.nexed.tech (same signed files):
                                     # test a release, then refresh the mirror to roll it out
                                     # removed from the policy: back to Debian's defaults
url_change:                          # make a server change happen sooner: a forced logout
  logout_at: "2026-10-12 18:00"      # local time, once; only while the change still waits
  warn_minutes: 15                   # default 15
session:
  logout_at: "00:00"                 # daily logout (shared machines, end of the day)
  warn_minutes: 10                   # default 10
screen_lock:
  after_minutes: 10                  # lock after this long idle; 0 = never
  on_suspend: true                   # lock when the computer sleeps
  enforced: true                     # changed settings are put back within a minute; without
                                     # it, a user's own change stays until the policy changes
wallpaper:                           # desktop and login screen (any image: JPEG, PNG, SVG)
  url: https://example.com/wallpaper.jpg
  sha256: <64 hex characters>        # sha256sum wallpaper.jpg; the file must match it
                                     # removed from the policy: NextDesk's own wallpaper
```

**Forced logouts** (`url_change`, `session`): `warn_minutes` before the time, everyone signed in
gets a notification and a countdown window ("Sign out now" or OK; it comes back for the last
minute). At the time the machine signs NextDesk users out itself, so closing the window doesn't
stop it. A policy that drops the logout before then cancels it. A machine that's off at the time
skips it.

**Wallpaper**: downloaded once per `sha256`; a download that fails or doesn't match keeps the
current wallpaper and is retried every 15 minutes. Running sessions switch to it straight away.
Users who picked their own wallpaper keep theirs.
