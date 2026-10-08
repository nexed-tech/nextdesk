"""Shared code for NextDesk sign-in: the PAM helper (root) and the greeter (lightdm user).

Files:
  /etc/nextdesk/nextdesk.conf          NEXTDESK_URL='...' (shell syntax, written by nextdesk-config)
  /var/lib/nextdesk/users.json         Nextcloud user id -> local username (readable by all)
  /var/lib/nextdesk/status.json        local username -> {displayname, has_pin} (readable by all;
                                       the greeter shows these users as tiles; no secrets)
  /var/lib/nextdesk/users/<user>/      root only: credentials.json (app password), state.json
                                       (last successful check, policy, PIN failures), pin.json
"""

import base64
import hashlib
import hmac
import json
import os
import pwd
import re
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

CONF = '/etc/nextdesk/nextdesk.conf'
STATE_DIR = '/var/lib/nextdesk'
MAPPING = os.path.join(STATE_DIR, 'users.json')
STATUS = os.path.join(STATE_DIR, 'status.json')
USERS_DIR = os.path.join(STATE_DIR, 'users')
SECRET_PREFIX = 'nextdesk1:'
PIN_PREFIX = 'nextdesk-pin1:'
TIMEOUT = 15
PIN_CHECK_TIMEOUT = 5      # is the server reachable at all; offline must not take long
AUTH_CHECK_TIMEOUT = 30    # the app password check itself (Nextcloud throttles failed logins)
PIN_MAX_FAILURES = 5


class ApiError(Exception):
    def __init__(self, status, message=''):
        super().__init__(f'HTTP {status} {message}'.strip())
        self.status = status


def read_conf():
    conf = {}
    try:
        with open(CONF, encoding='utf-8') as f:
            for line in f:
                m = re.match(r"^\s*([A-Z_]+)=['\"]?(.*?)['\"]?\s*$", line)
                if m:
                    conf[m.group(1)] = m.group(2)
    except OSError:
        pass
    return conf


def server_url():
    return read_conf().get('NEXTDESK_URL', '').rstrip('/')


# --- Users --------------------------------------------------------------------------------

def load_mapping():
    try:
        with open(MAPPING, encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_mapping(mapping):
    os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
    tmp = MAPPING + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(mapping, f, indent=2, sort_keys=True)
    os.chmod(tmp, 0o644)
    os.replace(tmp, MAPPING)


def local_user_exists(name):
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


USERNAME_RE = re.compile(r'^[a-z][a-z0-9_-]{0,30}$')


def valid_username(name):
    return bool(USERNAME_RE.match(name))


def username_for(display_name, nc_uid, mapping=None):
    """The local username for a Nextcloud user: the existing mapping, else derived from the
    display name: first initial + last name ("Stephan Craane" -> "scraane", "Ann Smith-Jones"
    -> "asmithjones"), or the single word; a number is added when the name is taken."""
    mapping = load_mapping() if mapping is None else mapping
    if nc_uid in mapping:
        return mapping[nc_uid]
    ascii_name = unicodedata.normalize('NFKD', display_name).encode('ascii', 'ignore').decode()
    # Words are split on spaces only, so "Smith-Jones" stays one surname.
    words = [w for w in (re.sub(r'[^a-z0-9]', '', part) for part in ascii_name.lower().split()) if w]
    if not words:
        words = [w for w in re.split(r'[^a-z0-9]+', nc_uid.split('@')[0].lower()) if w] or ['user']
    base = words[0][0] + words[-1] if len(words) > 1 else words[0]
    if not base[0].isalpha():
        base = 'u' + base
    base = base[:28]
    taken = set(mapping.values())
    name, n = base, 1
    while name in taken or local_user_exists(name):
        n += 1
        name = f'{base}{n}'
    return name


def user_dir(user):
    # A bad name ('' in particular) must never turn into USERS_DIR itself or a path outside it.
    if not valid_username(user):
        raise ValueError(f'invalid username {user!r}')
    return os.path.join(USERS_DIR, user)


def write_private_json(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# --- Secret passed from the greeter to PAM ------------------------------------------------

def encode_secret(login, app_password, new_pin=None):
    data = {'login': login, 'app_password': app_password}
    if new_pin:
        data['new_pin'] = new_pin
    return SECRET_PREFIX + base64.urlsafe_b64encode(json.dumps(data).encode()).decode()


def decode_secret(secret):
    """(login, app_password, new_pin or None), or None if this isn't a NextDesk secret."""
    if not secret.startswith(SECRET_PREFIX):
        return None
    try:
        data = json.loads(base64.urlsafe_b64decode(secret[len(SECRET_PREFIX):]))
        return data['login'], data['app_password'], data.get('new_pin')
    except (ValueError, KeyError, TypeError):
        return None


# --- PIN ----------------------------------------------------------------------------------

def valid_pin(pin):
    return isinstance(pin, str) and pin.isdigit() and 6 <= len(pin) <= 12


def hash_pin(pin):
    salt = os.urandom(16)
    n, r, p = 2 ** 15, 8, 1
    digest = hashlib.scrypt(pin.encode(), salt=salt, n=n, r=r, p=p, maxmem=64 * 1024 * 1024, dklen=32)
    return {'scheme': 'scrypt', 'n': n, 'r': r, 'p': p,
            'salt': base64.b64encode(salt).decode(), 'hash': base64.b64encode(digest).decode()}


def verify_pin(pin, record):
    try:
        digest = hashlib.scrypt(pin.encode(), salt=base64.b64decode(record['salt']),
                                n=record['n'], r=record['r'], p=record['p'], maxmem=64 * 1024 * 1024, dklen=32)
        return hmac.compare_digest(digest, base64.b64decode(record['hash']))
    except (KeyError, ValueError, TypeError):
        return False


# --- Status (world-readable, for the greeter) -----------------------------------------------

def load_status():
    data = read_json(STATUS)
    return data if isinstance(data, dict) else {}


def update_status(user, **fields):
    status = load_status()
    if fields.pop('remove', False):
        status.pop(user, None)
    else:
        status.setdefault(user, {}).update(fields)
    os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
    tmp = STATUS + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(status, f, indent=2, sort_keys=True)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATUS)


# --- Nextcloud ----------------------------------------------------------------------------

def _request(url, method='GET', data=None, auth=None, headers=None, timeout=TIMEOUT):
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    if auth:
        token = base64.b64encode(f'{auth[0]}:{auth[1]}'.encode()).decode()
        req.add_header('Authorization', f'Basic {token}')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def api(server, login, app_password, method, path, data=None, timeout=TIMEOUT):
    """Calls the NextDesk OCS API (/ocs/v2.php/apps/nextdesk/api/v1/<path>); returns ocs.data."""
    status, body = _request(f'{server}/ocs/v2.php/apps/nextdesk/api/v1/{path.lstrip("/")}',
                            method, data, (login, app_password),
                            {'OCS-APIRequest': 'true', 'Accept': 'application/json'}, timeout)
    if status != 200:
        raise ApiError(status)
    return json.loads(body)['ocs']['data']


def server_reachable(server, timeout=PIN_CHECK_TIMEOUT):
    """Does the server answer at all? status.php needs no login, so Nextcloud's brute-force
    throttling (which slows down answers to failed logins) doesn't apply to it."""
    try:
        status, body = _request(f'{server}/status.php', timeout=timeout)
        return status == 200 and json.loads(body).get('installed') is True and not json.loads(body).get('maintenance')
    except Exception:
        return False


def check_online(creds, timeout=PIN_CHECK_TIMEOUT, auth_timeout=AUTH_CHECK_TIMEOUT):
    """Asks the server whether this device's app password is still valid:
      ('ok', policy info)    valid
      ('revoked', None)      401: app password revoked, user disabled or deleted
      ('unverified', None)   the server is up but didn't confirm (slow, throttled, error)
      ('offline', None)      the server can't be reached (no network, down, maintenance)
    A revoked app password makes Nextcloud throttle the answers (up to ~25 s), so a slow answer
    from a reachable server is 'unverified', never 'offline'."""
    if not server_reachable(creds['server'], timeout):
        return 'offline', None
    try:
        return 'ok', api(creds['server'], creds['login'], creds['app_password'], 'GET', 'policy', timeout=auth_timeout)
    except ApiError as e:
        return ('revoked', None) if e.status == 401 else ('unverified', None)
    except Exception:
        return 'unverified', None


def login_flow_start(server, device_name):
    """Starts Nextcloud Login Flow v2; returns (login_url, poll_endpoint, poll_token).
    The device name (User-Agent) is what the user sees under Settings > Security."""
    status, body = _request(f'{server}/index.php/login/v2', 'POST', {},
                            headers={'User-Agent': device_name, 'Accept': 'application/json'})
    if status != 200:
        raise ApiError(status, 'starting login')
    data = json.loads(body)
    return data['login'], data['poll']['endpoint'], data['poll']['token']


def login_flow_poll(endpoint, token):
    """None while the user hasn't finished; then {'server', 'loginName', 'appPassword'}."""
    status, body = _request(endpoint, 'POST', {'token': token}, headers={'Accept': 'application/json'})
    if status == 404:
        return None
    if status != 200:
        raise ApiError(status, 'polling login')
    return json.loads(body)


# --- Per-user device state (root) ---------------------------------------------------------

def paths(user):
    """credentials.json, state.json and pin.json of a NextDesk user."""
    d = user_dir(user)
    return os.path.join(d, 'credentials.json'), os.path.join(d, 'state.json'), os.path.join(d, 'pin.json')


def save_state(user, **fields):
    state_path = paths(user)[1]
    state = read_json(state_path) or {}
    state.update(fields)
    write_private_json(state_path, state)


def checked_ok(user, info):
    """A successful check with the server: remember when, and the current policy."""
    import time
    displayname = info['user'].get('displayname', '')
    save_state(user, last_check=int(time.time()), policy=info.get('policy', {}), displayname=displayname)
    update_status(user, displayname=displayname, notice=None)


def remove_pin(user):
    try:
        os.remove(paths(user)[2])
    except FileNotFoundError:
        pass
    update_status(user, has_pin=False)


def forget_device(user, notice):
    """The device was revoked: delete the app password and PIN (the user's files stay). Only a
    full Nextcloud sign-in gets in again. The notice is shown on the login screen."""
    try:
        os.remove(paths(user)[0])
    except FileNotFoundError:
        pass
    remove_pin(user)
    update_status(user, notice=notice)


# --- Nextcloud remote wipe (Settings > Security > Devices > Wipe device) --------------------

def wipe_requested(creds, timeout=TIMEOUT):
    """True if the admin or user asked Nextcloud to wipe this device."""
    status, body = _request(f'{creds["server"]}/index.php/core/wipe/check', 'POST',
                            {'token': creds['app_password']}, headers={'Accept': 'application/json'},
                            timeout=timeout)
    if status != 200:
        return False   # 404: no wipe requested
    try:
        return json.loads(body).get('wipe') is True
    except ValueError:
        return False


def wipe_done(creds, timeout=TIMEOUT):
    """Tells Nextcloud the wipe is done; it then deletes the app password itself."""
    _request(f'{creds["server"]}/index.php/core/wipe/success', 'POST',
             {'token': creds['app_password']}, timeout=timeout)


# --- Disk recovery key escrow (encrypted installs) ------------------------------------------

RECOVERY_KEY = os.path.join(STATE_DIR, 'recovery-key.json')   # {key, disk_uuid}; root only
RECOVERY_KEY_STORED = os.path.join(STATE_DIR, 'recovery-key-stored.json')   # {server, by, at}: no key


def escrow_recovery_key(creds, timeout=TIMEOUT):
    """Uploads the disk's recovery key (from the installer or nextdesk-recovery-key --new) to
    Nextcloud with this user's app password, then deletes the local copy. Returns True when
    there was nothing to do or it's stored; raises ApiError when the server refused it (e.g. 404:
    a NextDesk app without escrow)."""
    pending = read_json(RECOVERY_KEY)
    if not pending:
        return True
    import socket
    with open('/etc/machine-id', encoding='ascii') as f:
        machine_id = f.read().strip()
    api(creds['server'], creds['login'], creds['app_password'], 'POST', 'recovery-key',
        {'machine_id': machine_id, 'hostname': socket.gethostname(), 'disk_uuid': pending.get('disk_uuid') or '',
         'key': pending['key']}, timeout=timeout)
    import time
    write_private_json(RECOVERY_KEY_STORED, {'server': creds['server'], 'by': creds['login'], 'at': int(time.time())})
    os.remove(RECOVERY_KEY)
    return True
