"""Shared code for NextDesk sign-in: the PAM helper (root) and the greeter (lightdm user).

Files:
  /etc/nextdesk/nextdesk.conf          NEXTDESK_URL='...' (shell syntax, written by nextdesk-config)
  /var/lib/nextdesk/users.json         Nextcloud user id -> local username (readable by all)
  /var/lib/nextdesk/users/<user>/      root only: credentials.json (app password), state.json
"""

import base64
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
USERS_DIR = os.path.join(STATE_DIR, 'users')
SECRET_PREFIX = 'nextdesk1:'
TIMEOUT = 15


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

def encode_secret(login, app_password):
    data = json.dumps({'login': login, 'app_password': app_password}).encode()
    return SECRET_PREFIX + base64.urlsafe_b64encode(data).decode()


def decode_secret(secret):
    if not secret.startswith(SECRET_PREFIX):
        return None
    try:
        data = json.loads(base64.urlsafe_b64decode(secret[len(SECRET_PREFIX):]))
        return data['login'], data['app_password']
    except (ValueError, KeyError, TypeError):
        return None


# --- Nextcloud ----------------------------------------------------------------------------

def _request(url, method='GET', data=None, auth=None, headers=None):
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    if auth:
        token = base64.b64encode(f'{auth[0]}:{auth[1]}'.encode()).decode()
        req.add_header('Authorization', f'Basic {token}')
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def api(server, login, app_password, method, path, data=None):
    """Calls the NextDesk OCS API (/ocs/v2.php/apps/nextdesk/api/v1/<path>); returns ocs.data."""
    status, body = _request(f'{server}/ocs/v2.php/apps/nextdesk/api/v1/{path.lstrip("/")}',
                            method, data, (login, app_password),
                            {'OCS-APIRequest': 'true', 'Accept': 'application/json'})
    if status != 200:
        raise ApiError(status)
    return json.loads(body)['ocs']['data']


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
