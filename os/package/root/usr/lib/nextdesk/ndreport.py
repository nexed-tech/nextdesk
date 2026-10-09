"""NextDesk computers page (NextDesk app 0.5.0+): this machine reports to its Nextcloud.

  check-in   with a signed-in user's app password (nextdesk-watchdog): registers the computer and
             its user, and gets a device token. At most hourly, and at once when the user, the
             policy in force or the version changed.
  contact    with the device token, no login (nextdesk-policy, every run): last contact, the
             policy in force (and when it was applied), the version.

Both send: machine id, hostname, policy {name, serial, source, applied_at}, version, installed_at.
The token is root-only (/var/lib/nextdesk/device-token.json) and belongs to one server: a
different Nextcloud URL, or a 403 from contact, drops it, and the next check-in asks for a new
one. A NextDesk app without these endpoints (404): nothing is sent until it has them.
"""

import json
import os
import socket
import subprocess
import time

import ndlib

TOKEN = os.path.join(ndlib.STATE_DIR, 'device-token.json')   # {server, token}; root only
STATE = os.path.join(ndlib.STATE_DIR, 'report-state.json')   # {checkin_at, checkin_key, ...}
POLICY = os.path.join(ndlib.STATE_DIR, 'policy.json')
INSTALLED_AT = '/etc/nextdesk/installed-at'   # written by the installer (epoch seconds)
CHECKIN_EVERY = 3600


def machine_id():
    with open('/etc/machine-id', encoding='ascii') as f:
        return f.read().strip()


def installed_at():
    """When NextDesk OS was installed: the installer's marker, else when /etc/machine-id was
    created (the installer creates it), else 0."""
    try:
        with open(INSTALLED_AT, encoding='ascii') as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        pass
    try:
        born = subprocess.run(['stat', '-c', '%W', '/etc/machine-id'], capture_output=True, text=True).stdout.strip()
        return int(born) if born and int(born) > 0 else 0
    except (OSError, ValueError):
        return 0


def version():
    try:
        return subprocess.run(['dpkg-query', '-W', '-f', '${Version}', 'nextdesk-desktop'],
                              capture_output=True, text=True).stdout.strip()
    except OSError:
        return ''


def policy():
    """The policy in force: {name, serial, source, applied_at} (applied_at: when policy.json was
    written, which is when nextdesk-policy took it), or {}."""
    current = ndlib.read_json(POLICY)
    if not current or not current.get('name'):
        return {}
    try:
        applied = int(os.stat(POLICY).st_mtime)
    except OSError:
        applied = 0
    # A policy received before 0.18.0 doesn't say where it came from: then it's the policy URL
    source = current.get('source') or ndlib.read_conf().get('NEXTDESK_POLICY_URL', '')
    return {'name': current['name'], 'serial': current.get('serial', 0), 'source': source, 'applied_at': applied}


def report():
    return {'machine_id': machine_id(), 'hostname': socket.gethostname(), 'policy': policy(),
            'version': version(), 'installed_at': installed_at()}


def token_for(server):
    data = ndlib.read_json(TOKEN) or {}
    return data.get('token') if data.get('server') == server else None


def drop_token():
    try:
        os.remove(TOKEN)
    except FileNotFoundError:
        pass


def check_in(creds, user, force=False):
    """Check-in with this user's app password, when due (see the module docstring). Returns
    True when it was sent, None when not due; raises on errors (ndlib.ApiError 404: an older app)."""
    server = creds['server']
    data = report()
    have_token = token_for(server) is not None
    # What makes a check-in due right away: another user, server, policy or version
    key = json.dumps([server, user, data['policy'].get('serial'), data['policy'].get('source'), data['version']])
    state = ndlib.read_json(STATE) or {}
    if not force and have_token and state.get('checkin_key') == key and \
            time.time() - state.get('checkin_at', 0) < CHECKIN_EVERY:
        return None
    answer = ndlib.api(server, creds['login'], creds['app_password'], 'POST', 'check-in',
                       dict(data, new_token=not have_token), as_json=True)
    if answer.get('token'):
        ndlib.write_private_json(TOKEN, {'server': server, 'token': answer['token']})
    state.update(checkin_at=int(time.time()), checkin_key=key)
    ndlib.write_private_json(STATE, state)
    return True


def contact(server):
    """The machine's own report (device token). Returns True when sent, False without a token
    for this server (or the server refused it: the token is dropped); raises on other errors."""
    token = token_for(server)
    if not token:
        return False
    try:
        ndlib.api(server, None, None, 'POST', 'contact', dict(report(), token=token), as_json=True)
    except ndlib.ApiError as e:
        if e.status == 403:
            drop_token()
            return False
        raise
    return True
