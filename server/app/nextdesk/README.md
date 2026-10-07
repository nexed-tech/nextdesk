# NextDesk (Nextcloud app)

Server side of NextDesk OS. Nextcloud 30–35.

## What it does

| Endpoint | Who | What |
|---|---|---|
| `GET /ocs/v2.php/apps/nextdesk/api/v1/policy` | device (app password) | The user (id, display name, email) and the NextDesk policy that applies to them |
| `POST /ocs/v2.php/apps/nextdesk/api/v1/session-token` (`redirect=/path`) | device, **app password only** | A one-time URL (valid 60 s) that logs the browser in |
| `GET /apps/nextdesk/login?user=…&token=…&redirect=…` | browser | Takes the token and creates a normal Nextcloud session (with remember-me cookie); falls back to the login page |
| `GET/PUT /ocs/v2.php/apps/nextdesk/api/v1/admin/policy` | admins (settings page, Lintune) | Read / change policy: `{"scope": "global"\|"group"\|"user", "id": "…", "policy": {…} \| null}` |

Devices get their app password through Nextcloud's own Login Flow v2, so sign-in works with
whatever Nextcloud uses (local accounts, LDAP, OIDC with Entra ID or Keycloak, SAML). Revoke or
wipe a device under the user's Settings → Security → Devices & sessions.

## Policy

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

## Install (Nextcloud AIO)

```sh
cd /tmp && rm -rf nextdesk-src && mkdir nextdesk-src
curl -fsSL https://codeload.github.com/nexed-tech/nextdesk/tar.gz/os-package | tar -xz -C nextdesk-src --strip-components=1
docker exec nextcloud-aio-nextcloud rm -rf /var/www/html/custom_apps/nextdesk
docker cp nextdesk-src/server/app/nextdesk nextcloud-aio-nextcloud:/var/www/html/custom_apps/nextdesk
docker exec nextcloud-aio-nextcloud chown -R www-data:www-data /var/www/html/custom_apps/nextdesk
docker exec -u www-data nextcloud-aio-nextcloud php occ app:enable nextdesk
```

(Replace `os-package` with `main` once merged.)
