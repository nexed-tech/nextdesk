# NextDesk (Nextcloud app)

Server side of NextDesk OS. Nextcloud 30–35.

## What it does

| Endpoint | Who | What |
|---|---|---|
| `GET /ocs/v2.php/apps/nextdesk/api/v1/policy` | device (app password) | The user (id, display name, email) and the NextDesk policy that applies to them |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/session-token` (`redirect=/path`) | device, **app password only** | A one-time URL (valid 60 s) that logs the browser in |
| `GET /apps/nextdesk/login?user=…&token=…&redirect=…` | browser | Takes the token and creates a normal Nextcloud session (with remember-me cookie); falls back to the login page |
| `GET/PUT /ocs/v2.php/apps/nextdesk/api/v1/admin/policy` | admins (settings page, Lintune) | Read / change policy: `{"scope": "global"\|"group"\|"user", "id": "…", "policy": {…} \| null}` |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/recovery-key` (`machine_id`, `key`, `hostname`, `disk_uuid`) | device, **app password only** | Escrow of the disk recovery key (encrypted installs); one per machine id, a new key replaces the old. Write-only |
| `GET /ocs/v2.php/apps/nextdesk/api/v1/device-policy` | public | The device policy for this server's NextDesk machines (`{"url": … | null, "per_hostname": bool, "departments": [...], "hostname_prefix": "…"}`); the installer and the machines read it |
| `GET/PUT /ocs/v2.php/apps/nextdesk/api/v1/admin/device-policy` (`url`, `per_hostname`, `departments`, `hostname_prefix`; each optional) | admins (settings page, Lintune) | Read / set the device policy URL (https, or empty to remove), policy per hostname group, departments, computer name prefix |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/check-in` (`machine_id`, `hostname`, `policy: {name, serial, source, applied_at}`, `version`, `installed_at`, `new_token`) | device, **app password only** | Registers the computer and its user; answers with a device token (`token`) when it has none yet or asks for one |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/contact` (`machine_id`, `token`, `policy`, `version`, `installed_at`) | the machine (device token), no login | Last contact, policy in force, version; answers `rotate_admin_password` (its admin password was shown: set a new one). Wrong token: 403, throttled (brute force protection) |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/enroll` (`enrollment_token`, `machine_id`, `hostname`, `version`, `installed_at`) | a new computer (enrollment token), no login | Registers it at its first start; answers with its device token. Wrong / expired / revoked token: 403, throttled |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/device-secrets` (`machine_id`, `token`, `recovery_key`, `disk_uuid`, `admin_user`, `admin_password`) | the machine (device token), no login | Escrow of its disk recovery key and/or local admin password. Write-only |
| `GET/POST /ocs/v2.php/apps/nextdesk/api/v1/admin/enrollment-tokens`, `DELETE …/<id>` | admins (settings page) | Valid tokens (without the tokens) / a new one (`{id, token, expires_at, server}`; always 24 hours) / revoke |
| `GET /ocs/v2.php/apps/nextdesk/api/v1/computers?search=&limit=50&offset=0` | admins + delegated groups | A page of computers (`{computers, total, can_delete}`), no keys |
| `GET /ocs/v2.php/apps/nextdesk/api/v1/computers/<machine id>/recovery-key` | admins + delegated groups | The key (logged) |
| `GET /ocs/v2.php/apps/nextdesk/api/v1/computers/<machine id>/admin-password` | admins + delegated groups | The local admin account and password (logged); the computer then sets a new one |
| `DELETE /ocs/v2.php/apps/nextdesk/api/v1/computers/<machine id>` | admins | Remove a computer and its key |
| `GET /ocs/v2.php/apps/nextdesk/api/v1/admin/recovery-keys[/<hostname or machine id>]` | admins | The computers with a stored key; with a computer, its key (every read is logged). As in 0.4.0 |
| `DELETE /ocs/v2.php/apps/nextdesk/api/v1/admin/recovery-keys/<machine id>` | admins | Remove a computer and its key. As in 0.4.0 |

Devices get their app password through Nextcloud's own Login Flow v2, so sign-in works with
whatever Nextcloud uses (local accounts, LDAP, OIDC with Entra ID or Keycloak, SAML). Revoke or
wipe a device under the user's Settings → Security → Devices & sessions.

## Device policy

Administration settings → Security → NextDesk → **Device policy**: the full URL of the signed
NextDesk device policy for this server's machines (e.g.
`https://repo.nexed.tech/policy/nexed.json`; see `policies/README.md` in the repo). The installer
reads it, and machines follow a change within 15 minutes. One URL for all machines of this
Nextcloud; empty = machines keep their own setting. Also settable through the admin API.

**Policy per hostname group** (checkbox): machines first look for a policy named after the part
of their computer name before the first `-`, in the same directory as that URL (`sales-001` →
`…/policy/sales.json`); the URL above is the fallback (no `-` in the name, or no such file, HTTP
404). A renamed machine moves to its new group within 15 minutes.

**Departments** (one per line, lowercase letters and digits): the installer offers them after
the server check and proposes `<department>-<last 6 hex digits of the MAC>` as the computer name
(e.g. `sales-F5D411`; still editable), so with policies per hostname group that machine gets
`sales.json` straight away.

**Computer name prefix** (lowercase letters and digits): what the installer puts before the 6 hex
digits when no department is picked (`company-F5D411`), so every computer gets its own name.
Empty: the server's theming name, made hostname-safe (`Nexed.Tech` → `nexedtech`), else `nextdesk`.

## User policy

Layers, most specific wins: **user override → group overrides → global → built-in default**.
When a user is in several groups that set the same key, the strictest value wins.

| Key | Default | Meaning |
|---|---|---|
| `offline_grace_days` | 7 | Days a device may be signed in to offline (with the user's PIN) since it last reached this server. 0 = never offline. |

Manage it under **Administration settings → Security → NextDesk**, or:

```sh
occ nextdesk:policy                                    # show everything
occ nextdesk:policy offline_grace_days 7               # global
occ nextdesk:policy --group field offline_grace_days 30
occ nextdesk:policy --user alice offline_grace_days 0
occ nextdesk:policy --user alice --delete
occ nextdesk:policy --effective alice                  # what applies to alice
```

## Computers and disk recovery keys

**Administration settings → NextDesk computers** (its own section): every computer that reported
in, with its last contact, last user, the device policy in force (name, serial, when applied),
the NextDesk OS version, the install date, and its disk recovery key. Search (computer name,
machine id, user) and pages of 50, most recent contact first.

- **Reporting:** a computer is registered by its first report with a signed-in user's app
  password (`check-in`), which also gives it a device token. With that token the machine reports
  by itself (`contact`: every 15 minutes and when it applies a policy), also with nobody signed in.
  A computer where nobody ever signed in doesn't appear yet.
- **Helpdesk access:** Administration settings → Administration privileges → NextDesk computers
  → add a group (e.g. `helpdesk`). Its members get this section only (not the policy settings
  under Security): they can search computers and show recovery keys, not delete computers.
- **Logged** (Nextcloud log, warning level): every recovery key shown (`… shown to <user>`) and
  every computer deleted (`… deleted by <user>`).

Encrypted NextDesk installs (TPM or passphrase) upload their disk recovery key at the first
sign-in, like BitLocker keys in Intune. Keys are stored encrypted with the instance secret.
Also with `occ`:

```sh
occ nextdesk:recovery-key                    # computers with a stored key (no keys)
occ nextdesk:recovery-key nd-office-3        # the key (hostname or machine id; logged)
occ nextdesk:recovery-key --delete <machine id>   # the computer and its key
```

On the device, `nextdesk-recovery-key` shows the status and `nextdesk-recovery-key --new`
replaces the key (the old one stops working) and stores the new one.

## Enrollment and local admin passwords

Administration settings → Security → NextDesk → **Enrollment** → *Create enrollment token*: valid
from then until 24 hours later (no choice; revocable in the list below it, which also shows how many
computers enrolled with each). *Download nextdesk-install.json* gives the file for the installer's USB
stick (next to the ISO with Ventoy); the token can also be typed in the installer. A computer
installed with it registers itself at its first start and stores its disk recovery key and its local
admin password here, before anyone signs in. The token can only register computers and store their
own secrets.

Every NextDesk computer has a local admin account (`localadmin`, sudo) with a **random password of
its own** (root is locked). Computers page → *Local admin* → *Show* reveals it (logged); the computer
then sets a new one at its next contact (within about 15 minutes) and stores that, so a password that
was given out stops working. Without an enrollment token, the password is stored after the first
sign-in, like the recovery key.

## Install (Nextcloud AIO)

```sh
cd /tmp && rm -rf nextdesk-src && mkdir nextdesk-src
curl -fsSL https://codeload.github.com/nexed-tech/nextdesk/tar.gz/main | tar -xz -C nextdesk-src --strip-components=1
docker exec nextcloud-aio-nextcloud rm -rf /var/www/html/custom_apps/nextdesk
docker cp nextdesk-src/server/app/nextdesk nextcloud-aio-nextcloud:/var/www/html/custom_apps/nextdesk
docker exec nextcloud-aio-nextcloud chown -R www-data:www-data /var/www/html/custom_apps/nextdesk
docker exec -u www-data nextcloud-aio-nextcloud php occ app:enable nextdesk
docker exec -u www-data nextcloud-aio-nextcloud php occ upgrade   # after an update: database changes
```

### Notifications with all apps closed (Web Push)

NextDesk machines allow the web apps' notifications without asking. While an app is open,
Nextcloud delivers them itself. With all apps closed they need **Web Push**, which is off by
default. Turn it on once per server (notifications app 8.0+, Nextcloud 35). The notifications app
itself must be enabled: without it there are no notifications at all, and its admin page answers
"Forbidden".

```sh
docker exec -u www-data nextcloud-aio-nextcloud php occ app:enable notifications
docker exec -u www-data nextcloud-aio-nextcloud php occ config:app:set notifications webpush_enabled --type=boolean --value=true
docker exec -u www-data nextcloud-aio-nextcloud php occ config:app:set notifications webpush_browsers_enabled --type=boolean --value=true
```

Check the app version with `occ app:list | grep notifications`. Each user's browser signs up for
push the next time they open any Nextcloud app. The same switches are under Administration
settings → Notifications (`/settings/admin/notifications`), for an admin account.

