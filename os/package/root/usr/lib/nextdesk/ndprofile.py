"""The user's NextDesk preferences follow them: ~/.config/nextdesk/profile.json (written by
nextdesk-session-agent when the user changes a setting) <-> <files>/.nextdesk/profile.json in
their Nextcloud, with the device's app password.

  {"keyboard": {"layout": "us", "variant": "altgr-intl"}, "updated": <unix time>}

  pull   at sign-in (nextdesk-pam open_session), before the session agent applies it
  push   at sign-out (nextdesk-profile push, a few seconds later) and by the watchdog

A preference needs no merge: the copy with the newest "updated" wins. The user's layout also
goes in status.json, so the login screen can switch to it when their tile is picked.

Runs as root; the local file is read and written as the user (setpriv).
State (root only): /var/lib/nextdesk/users/<user>/profile.json = {etag, hash}.
"""

import hashlib
import json
import os
import pwd

import ndlib

TIMEOUT = 10
REMOTE = '.nextdesk/profile.json'


def _local_path(user):
    return os.path.join(pwd.getpwnam(user).pw_dir, '.config', 'nextdesk', 'profile.json')


def _valid(data):
    return isinstance(data, dict) and isinstance(data.get('updated', 0), (int, float))


def _read_local(user):
    r = ndlib.as_user(user, ['/bin/cat', _local_path(user)])
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
        return data if _valid(data) else None
    except ValueError:
        return None


def _write_local(user, data):
    body = json.dumps(data, indent=2).encode()
    r = ndlib.as_user(user, ['/bin/sh', '-c', 'umask 077 && mkdir -p "$1" && cat > "$1/.profile.json.nextdesk" && '
                             'mv -f "$1/.profile.json.nextdesk" "$1/profile.json"', 'sh',
                             os.path.dirname(_local_path(user))], body)
    if r.returncode != 0:
        raise OSError(r.stderr.decode(errors='replace').strip() or 'writing profile.json failed')


def _hash(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def _state_path(user):
    return os.path.join(ndlib.user_dir(user), 'profile.json')


def _context(user):
    creds = ndlib.read_json(ndlib.paths(user)[0])
    uid = ndlib.nc_uid(user)
    return (creds, uid) if creds and uid else (None, None)


def _publish_keyboard(user, data):
    """The login screen switches to the user's layout when their tile is picked."""
    kb = (data or {}).get('keyboard')
    if isinstance(kb, dict) and kb.get('layout'):
        ndlib.update_status(user, keyboard={'layout': kb['layout'], 'variant': kb.get('variant', '')})
    else:   # back to the computer's default
        ndlib.update_status(user, keyboard=None)


def _get(creds, uid):
    status, body, headers = ndlib.dav(creds, ndlib.dav_url(creds, uid, REMOTE), timeout=TIMEOUT)
    if status == 404:
        return None, None
    if status != 200:
        raise ndlib.ApiError(status)
    data = json.loads(body)
    return (data if _valid(data) else None), headers.get('ETag')


def _put(creds, uid, data):
    url = ndlib.dav_url(creds, uid, REMOTE)
    body = json.dumps(data, indent=2).encode()
    status, _, headers = ndlib.dav(creds, url, 'PUT', body, {'Content-Type': 'application/json'}, TIMEOUT)
    if status in (404, 409):   # no .nextdesk folder yet
        ndlib.dav(creds, ndlib.dav_url(creds, uid, '.nextdesk'), 'MKCOL', timeout=TIMEOUT)
        status, _, headers = ndlib.dav(creds, url, 'PUT', body, {'Content-Type': 'application/json'}, TIMEOUT)
    if status not in (200, 201, 204):
        raise ndlib.ApiError(status)
    return headers.get('ETag')


def pull(user):
    """Sign-in: the newest of the local and the server's copy becomes both."""
    creds, uid = _context(user)
    if not creds:
        return 'not signed in with Nextcloud'
    remote, etag = _get(creds, uid)
    local = _read_local(user)
    if remote is None and local is None:
        return 'nothing to sync yet'
    if local is None or (remote is not None and remote.get('updated', 0) > local.get('updated', 0)):
        _write_local(user, remote)
        result, data = 'downloaded', remote
    elif remote is None or local.get('updated', 0) > remote.get('updated', 0):
        etag = _put(creds, uid, local)
        result, data = 'uploaded', local
    else:
        result, data = 'up to date', local
    ndlib.write_private_json(_state_path(user), {'etag': etag, 'hash': _hash(data)})
    _publish_keyboard(user, data)
    return result


def push(user):
    """Sign-out / while signed in: uploads the local copy when it changed."""
    creds, uid = _context(user)
    if not creds:
        return 'not signed in with Nextcloud'
    local = _read_local(user)
    if local is None:
        return 'no profile'
    state = ndlib.read_json(_state_path(user)) or {}
    if _hash(local) == state.get('hash'):
        return 'unchanged'
    remote, _ = _get(creds, uid)
    if remote is not None and remote.get('updated', 0) > local.get('updated', 0):
        return 'server copy is newer; kept (next sign-in)'
    etag = _put(creds, uid, local)
    ndlib.write_private_json(_state_path(user), {'etag': etag, 'hash': _hash(local)})
    _publish_keyboard(user, local)
    return 'uploaded'
