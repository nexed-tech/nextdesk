"""Browser bookmarks follow the user: kept in their own Nextcloud, as
<files>/.nextdesk/bookmarks.json (Chrome's Bookmarks file), with the device's app password.

  pull   at sign-in (nextdesk-pam open_session), before the session starts the browser: the
         server's copy replaces the local one, so a new computer gets the user's bookmarks
  push   at sign-out (nextdesk-pam close_session, a few seconds later) and every few minutes
         while the user is on the desktop (nextdesk-watchdog): a changed local copy is uploaded

Chrome's own sync stays off (SyncDisabled, BrowserSignin in nextdesk-os.json). Both sides
changed since the last sync (offline edits, or two computers at once): the side being applied
wins, and bookmarks the other side added go in a folder "From <where>" under Other bookmarks,
so nothing added is lost. Every upload is a new file version in Nextcloud, which is the undo.

Runs as root, but every file in the home directory is read and written as the user (setpriv),
so a symlink there can't make root read or overwrite anything else.

State (root only): /var/lib/nextdesk/users/<user>/bookmarks.json = {etag, hash, base}: the
server's ETag, and the hash and content of what was last synced.
"""

import base64
import contextlib
import copy
import fcntl
import hashlib
import json
import os
import pwd
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import ndlib

TIMEOUT = 10
REMOTE_DIR = '.nextdesk'
REMOTE_FILE = 'bookmarks.json'
ROOT_NAMES = ('bookmark_bar', 'other', 'synced')


def _uid_of(user):
    """The Nextcloud user id linked to a local user (the WebDAV path needs it, not the login)."""
    for nc_uid, local in ndlib.load_mapping().items():
        if local == user:
            return nc_uid
    return None


def _profile_dir(user):
    """Chrome's Default profile (Chromium's when Chrome isn't installed, as nextdesk-session-init)."""
    home = pwd.getpwnam(user).pw_dir
    browser = 'google-chrome' if os.path.exists('/opt/google/chrome') else 'chromium'
    return os.path.join(home, '.config', browser), os.path.join(home, '.config', browser, 'Default')


def _as_user(user, args, data=None):
    pw = pwd.getpwnam(user)
    return subprocess.run(['/usr/bin/setpriv', f'--reuid={pw.pw_uid}', f'--regid={pw.pw_gid}', '--init-groups',
                           '--', *args], input=data, capture_output=True, timeout=30, check=False)


def _read_local(user):
    r = _as_user(user, ['/bin/cat', os.path.join(_profile_dir(user)[1], 'Bookmarks')])
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
        return data if isinstance(data.get('roots'), dict) else None
    except ValueError:
        return None


def _write_local(user, data):
    body = json.dumps(data, indent=3, ensure_ascii=False).encode()
    r = _as_user(user, ['/bin/sh', '-c', 'umask 077 && mkdir -p "$1" && cat > "$1/.Bookmarks.nextdesk" && '
                        'mv -f "$1/.Bookmarks.nextdesk" "$1/Bookmarks"', 'sh', _profile_dir(user)[1]], body)
    if r.returncode != 0:
        raise OSError(r.stderr.decode(errors='replace').strip() or 'writing Bookmarks failed')


def browser_running(user):
    """Chrome's SingletonLock is a symlink to "<host>-<pid>" while the profile is in use."""
    try:
        host, _, pid = os.readlink(os.path.join(_profile_dir(user)[0], 'SingletonLock')).rpartition('-')
        os.kill(int(pid), 0)
        return host == socket.gethostname()
    except (OSError, ValueError):
        return False


def _clean(data):
    """Only what we sync: Chrome recomputes the checksum, and sync metadata belongs to Chrome sync."""
    return {'roots': {k: v for k, v in data['roots'].items() if k in ROOT_NAMES}, 'version': data.get('version', 1)}


def _hash(data):
    return hashlib.sha256(json.dumps(data['roots'], sort_keys=True).encode()).hexdigest()


# --- Merge --------------------------------------------------------------------------------

def _urls(node, out=None):
    out = set() if out is None else out
    if node.get('type') == 'url':
        out.add(node.get('url'))
    for child in node.get('children', ()):
        _urls(child, out)
    return out


def _all_urls(data):
    out = set()
    for root in (data or {}).get('roots', {}).values():
        if isinstance(root, dict):
            _urls(root, out)
    return out


def _added(node, skip, out):
    """Bookmarks in node whose URL is in neither the base nor the winning side, in order."""
    if node.get('type') == 'url' and node.get('url') not in skip:
        skip.add(node.get('url'))
        out.append(node)
    for child in node.get('children', ()):
        _added(child, skip, out)


def merge(primary, other, base, label):
    """primary with the bookmarks other added since base appended in "From <label>"."""
    skip = _all_urls(base) | _all_urls(primary)
    added = []
    for name in ROOT_NAMES:
        if isinstance(other['roots'].get(name), dict):
            _added(other['roots'][name], skip, added)
    merged = copy.deepcopy(primary)
    if not added:
        return merged
    next_id = max([int(i) for i in _ids(merged) if i.isdigit()] or [0]) + 1
    now = str(int((time.time() + 11644473600) * 1_000_000))   # Chrome: microseconds since 1601
    folder = {'type': 'folder', 'name': f'From {label}', 'id': str(next_id), 'guid': str(uuid.uuid4()),
              'date_added': now, 'date_modified': now, 'children': []}
    for i, node in enumerate(added, next_id + 1):
        folder['children'].append({'type': 'url', 'name': node.get('name', ''), 'url': node['url'],
                                   'id': str(i), 'guid': str(uuid.uuid4()), 'date_added': node.get('date_added', now)})
    merged['roots'].setdefault('other', {'type': 'folder', 'name': 'Other bookmarks', 'children': []})
    merged['roots']['other'].setdefault('children', []).append(folder)
    return merged


def _ids(data):
    stack = [r for r in data['roots'].values() if isinstance(r, dict)]
    while stack:
        node = stack.pop()
        yield str(node.get('id', ''))
        stack.extend(node.get('children', ()))


# --- Nextcloud (WebDAV) -------------------------------------------------------------------

def _dav(creds, nc_uid, method, path='', body=None, headers=None):
    """(status, body, etag) for <files of nc_uid>/.nextdesk/<path>."""
    url = (f'{creds["server"]}/remote.php/dav/files/{urllib.parse.quote(nc_uid, safe="")}/{REMOTE_DIR}'
           + (f'/{path}' if path else ''))
    req = urllib.request.Request(url, data=body, method=method, headers=dict(headers or {}))
    token = base64.b64encode(f'{creds["login"]}:{creds["app_password"]}'.encode()).decode()
    req.add_header('Authorization', f'Basic {token}')
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, resp.read(), resp.headers.get('ETag')
    except urllib.error.HTTPError as e:
        return e.code, e.read(), None


def _get(creds, nc_uid):
    """(data, etag), (None, None) when there's no copy on the server yet."""
    status, body, etag = _dav(creds, nc_uid, 'GET', REMOTE_FILE)
    if status == 404:
        return None, None
    if status != 200:
        raise ndlib.ApiError(status)
    data = json.loads(body)
    if not isinstance(data.get('roots'), dict):
        raise ValueError('not a bookmarks file')
    return _clean(data), etag


def _put(creds, nc_uid, data, etag):
    """Uploads data; only over the version we know (etag), or as a new file (None). Returns the new
    ETag, or None when the server's copy changed in between (412)."""
    body = json.dumps(data, indent=1, ensure_ascii=False).encode()
    headers = {'Content-Type': 'application/json', **({'If-Match': etag} if etag else {'If-None-Match': '*'})}
    status, _, new_etag = _dav(creds, nc_uid, 'PUT', REMOTE_FILE, body, headers)
    if status in (404, 409):   # no .nextdesk folder yet
        _dav(creds, nc_uid, 'MKCOL')
        status, _, new_etag = _dav(creds, nc_uid, 'PUT', REMOTE_FILE, body, headers)
    if status == 412:
        return None
    if status not in (200, 201, 204):
        raise ndlib.ApiError(status)
    return new_etag or _get(creds, nc_uid)[1]


# --- Sync ---------------------------------------------------------------------------------

@contextlib.contextmanager
def _locked(user):
    """One sync per user at a time (the watchdog and a sign-out can meet)."""
    path = os.path.join(ndlib.user_dir(user), 'bookmarks.lock')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _state_path(user):
    return os.path.join(ndlib.user_dir(user), 'bookmarks.json')


def _save(user, etag, data):
    ndlib.write_private_json(_state_path(user), {'etag': etag, 'hash': _hash(data), 'base': data})


def _context(user):
    creds = ndlib.read_json(ndlib.paths(user)[0])
    nc_uid = _uid_of(user)
    if not creds or not nc_uid:
        return None
    return creds, nc_uid, ndlib.read_json(_state_path(user)) or {}


def pull(user):
    """Sign-in: makes the local bookmarks the server's (merged with unsynced local additions).
    Returns what it did, for the log."""
    ctx = _context(user)
    if not ctx:
        return 'not signed in with Nextcloud'
    creds, nc_uid, state = ctx
    if browser_running(user):
        return 'browser already running'
    with _locked(user):
        remote, etag = _get(creds, nc_uid)
        raw = _read_local(user)
        local = _clean(raw) if raw else None
        if remote is None:
            if local is None:
                return 'nothing to sync yet'
            new_etag = _put(creds, nc_uid, local, None)
            if new_etag is None:
                return 'server copy appeared meanwhile; next time'
            _save(user, new_etag, local)
            return 'first upload'
        local_changed = local is not None and _hash(local) != state.get('hash')
        if local_changed and etag != state.get('etag'):
            # Both sides changed (or this computer's first sync, with bookmarks of its own): the
            # server's wins, this computer's additions are kept
            merged = merge(remote, local, state.get('base'), socket.gethostname())
            new_etag = _put(creds, nc_uid, merged, etag) if _hash(merged) != _hash(remote) else etag
            if new_etag is None:
                return 'server copy changed meanwhile; next time'
            remote, etag, result = merged, new_etag, 'merged'
        elif local_changed and etag == state.get('etag'):
            # Only this computer changed (signed out offline): upload instead
            new_etag = _put(creds, nc_uid, local, etag)
            if new_etag is None:
                return 'server copy changed meanwhile; next time'
            _save(user, new_etag, local)
            return 'uploaded unsynced changes'
        else:
            result = 'downloaded'
        if local is None or _hash(local) != _hash(remote):
            _write_local(user, remote)
        else:
            result = 'up to date'
        _save(user, etag, remote)
        return result


def push(user):
    """Sign-out / while signed in: uploads the local bookmarks when they changed."""
    ctx = _context(user)
    if not ctx:
        return 'not signed in with Nextcloud'
    creds, nc_uid, state = ctx
    with _locked(user):
        raw = _read_local(user)
        if not raw:
            return 'no local bookmarks'
        local = _clean(raw)
        if _hash(local) == state.get('hash'):
            return 'unchanged'
        new_etag = _put(creds, nc_uid, local, state.get('etag'))
        result = 'uploaded'
        if new_etag is None:
            # Changed on another computer too: this one (in use now) wins, the other's additions
            # are kept. The browser here gets them at the next sign-in (pull).
            remote, etag = _get(creds, nc_uid)
            merged = merge(local, remote, state.get('base'), 'another computer') if remote else local
            new_etag = _put(creds, nc_uid, merged, etag)
            if new_etag is None:
                return 'server copy changed meanwhile; next time'
            # hash = the local copy, so an unchanged browser isn't uploaded again; base = merged
            ndlib.write_private_json(_state_path(user), {'etag': new_etag, 'hash': _hash(local), 'base': merged})
            return 'merged'
        _save(user, new_etag, local)
        return result
