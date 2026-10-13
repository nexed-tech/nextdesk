"""Downloads follow the user: finished files in ~/Downloads are moved to their Nextcloud
(<files>/<downloads.folder>, default Downloads) with the device's app password.

  upload    nextdesk-downloads@<user>.path (inotify on ~/Downloads, started at sign-in by
            nextdesk-pam) starts nextdesk-downloads@<user>.service within seconds of a finished
            download; the watchdog runs it too, for anything missed (offline at the time)
  cleanup   local copies go downloads.keep_local_days (default 7) after they're safely in
            Nextcloud and unchanged since; 0 = at sign-out. Files that weren't uploaded, or changed
            since, always stay.

Chrome downloads to <name>.crdownload and renames the file when it's done, so only finished
files are seen (partial-download names are skipped). Files bigger than CHUNK go up in chunks
(Nextcloud chunked upload v2), with progress for the session: /run/nextdesk/downloads/<user>.json,
shown by nextdesk-session-agent as one notification with a progress bar. A name that already
exists in Nextcloud (and isn't this computer's earlier upload of the same file) gets " (2)".

Runs as root; files in the home directory are listed, read and removed as the user (setpriv).
State (root only): /var/lib/nextdesk/users/<user>/downloads.json = {files: {name: {size, mtime,
remote, uploaded_at}}}.
"""

import contextlib
import fcntl
import json
import os
import pwd
import subprocess
import time
import uuid

import ndlib

CHUNK = 10 * 2**20
TIMEOUT = 120
PARTIAL = ('.crdownload', '.part', '.partial', '.download', '.tmp')
PROGRESS_DIR = '/run/nextdesk/downloads'
POLICY = os.path.join(ndlib.STATE_DIR, 'policy.json')


class Offline(Exception):
    pass


def settings():
    d = (ndlib.read_json(POLICY) or {}).get('downloads') or {}
    return {'sync': d.get('sync', True), 'folder': d.get('folder', 'Downloads'),
            'keep_local_days': d.get('keep_local_days', 7)}


def _downloads_dir(user):
    return os.path.join(pwd.getpwnam(user).pw_dir, 'Downloads')


def list_local(user):
    """{name: (size, mtime)} of the files directly in ~/Downloads (no folders, no hidden files)."""
    r = ndlib.as_user(user, ['/usr/bin/find', _downloads_dir(user), '-mindepth', '1', '-maxdepth', '1',
                             '-type', 'f', '-printf', '%f\\0%s\\0%T@\\0'])
    if r.returncode != 0:
        return {}
    parts = r.stdout.decode('utf-8', 'surrogateescape').split('\0')
    files = {}
    for i in range(0, len(parts) - 2, 3):
        name, size, mtime = parts[i], parts[i + 1], parts[i + 2]
        if name and not name.startswith('.'):
            files[name] = (int(size), int(float(mtime)))
    return files


class Busy(Exception):
    pass


@contextlib.contextmanager
def _locked(user, wait=True):
    """One upload or cleanup per user at a time; wait=False raises Busy instead of waiting."""
    fd = os.open(os.path.join(ndlib.user_dir(user), 'downloads.lock'), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            raise Busy() from None
        yield
    finally:
        os.close(fd)


def _state_path(user):
    return os.path.join(ndlib.user_dir(user), 'downloads.json')


# --- Progress, for the session agent -------------------------------------------------------

class Progress:
    """/run/nextdesk/downloads/<user>.json, root's file in root's directory (no symlink games),
    readable by the user's group: {run, visible, items: [{name, done, total, state}], error}."""

    def __init__(self, user):
        self.path = os.path.join(PROGRESS_DIR, f'{user}.json')
        self.gid = pwd.getpwnam(user).pw_gid
        self.data = {'run': uuid.uuid4().hex, 'visible': False, 'items': [], 'error': None, 'folder': ''}
        self.last = 0

    def item(self, name, total):
        entry = {'name': name, 'done': 0, 'total': total, 'state': 'moving'}
        self.data['items'].append(entry)
        if total > CHUNK:
            self.data['visible'] = True   # small files are done before a notification would help
        self.write(True)
        return entry

    def write(self, force=False):
        if not force and time.time() - self.last < 0.5:
            return
        self.last = time.time()
        os.makedirs(PROGRESS_DIR, mode=0o755, exist_ok=True)
        tmp = f'{self.path}.tmp'
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o640)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(self.data, f)
        os.chown(tmp, 0, self.gid)
        os.replace(tmp, self.path)


# --- Nextcloud ----------------------------------------------------------------------------

def _request(creds, url, method, body=None, headers=None):
    try:
        return ndlib.dav(creds, url, method, body, headers, TIMEOUT)
    except OSError as e:   # URLError, timeouts, connection resets
        raise Offline(str(e)) from e


def _ensure_folder(creds, uid, folder):
    path = ''
    for part in folder.split('/'):
        path = f'{path}/{part}' if path else part
        status, _, _ = _request(creds, ndlib.dav_url(creds, uid, path), 'MKCOL')
        if status not in (201, 405):   # 405: exists
            raise ndlib.ApiError(status)


def _candidates(name):
    stem, dot, ext = name.rpartition('.')
    if not stem:
        stem, dot, ext = name, '', ''
    yield name
    for n in range(2, 100):
        yield f'{stem} ({n}){dot}{ext}'


def _put_small(creds, uid, user, local, folder, name, overwrite):
    r = ndlib.as_user(user, ['/bin/cat', local], timeout=60)
    if r.returncode != 0:
        raise FileNotFoundError(local)
    for candidate in ([name] if overwrite else _candidates(name)):
        headers = {} if overwrite else {'If-None-Match': '*'}
        status, _, _ = _request(creds, ndlib.dav_url(creds, uid, f'{folder}/{candidate}'), 'PUT', r.stdout, headers)
        if status in (200, 201, 204):
            return candidate
        if status != 412:
            raise ndlib.ApiError(status)
    raise RuntimeError(f'no free name for {name}')


def _put_chunked(creds, uid, user, local, size, folder, name, overwrite, entry, progress):
    """Nextcloud chunked upload v2: MKCOL an upload folder, PUT numbered chunks, MOVE .file to the
    destination. The chunks stay until the MOVE, so a name clash only retries the MOVE."""
    upload = ndlib.dav_url(creds, uid, f'nextdesk-{uuid.uuid4().hex}', kind='uploads')
    dest = ndlib.dav_url(creds, uid, f'{folder}/{name}')
    reader = ndlib.as_user(user, ['/bin/cat', local], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        status, _, _ = _request(creds, upload, 'MKCOL', headers={'Destination': dest})
        if status not in (201, 405):
            raise ndlib.ApiError(status)
        n = 0
        while True:
            data = reader.stdout.read(CHUNK)
            if not data:
                break
            n += 1
            status, _, _ = _request(creds, f'{upload}/{n}', 'PUT', data,
                                    {'Destination': dest, 'OC-Total-Length': str(size)})
            if status not in (200, 201, 204):
                raise ndlib.ApiError(status)
            entry['done'] = min(size, entry['done'] + len(data))
            progress.write()
        if reader.wait() != 0 or entry['done'] != size:
            raise FileNotFoundError(local)   # gone or changed while reading
        for candidate in ([name] if overwrite else _candidates(name)):
            status, _, _ = _request(creds, f'{upload}/.file', 'MOVE', headers={
                'Destination': ndlib.dav_url(creds, uid, f'{folder}/{candidate}'),
                'OC-Total-Length': str(size), 'Overwrite': 'T' if overwrite else 'F'})
            if status in (200, 201, 204):
                return candidate
            if status != 412:
                raise ndlib.ApiError(status)
        raise RuntimeError(f'no free name for {name}')
    except BaseException:
        reader.kill()
        with contextlib.suppress(Exception):
            _request(creds, upload, 'DELETE')
        raise
    finally:
        reader.wait()


# --- Upload and clean up ------------------------------------------------------------------

def _todo(user, state):
    """Finished files that are new, or changed since this computer uploaded them."""
    todo = []
    for name, (size, mtime) in sorted(list_local(user).items()):
        if name.lower().endswith(PARTIAL):
            continue   # still downloading: Chrome renames it when it's done, which triggers us again
        known = state['files'].get(name)
        if known and known['size'] == size and known['mtime'] == mtime:
            continue
        todo.append((name, size, mtime, known))
    return todo


def upload(user):
    """Moves new and changed downloads to Nextcloud. Returns what it did, for the log."""
    s = settings()
    if not s['sync']:
        return 'off (device policy)'
    creds = ndlib.read_json(ndlib.paths(user)[0])
    uid = ndlib.nc_uid(user)
    if not creds or not uid:
        return 'not signed in with Nextcloud'
    folder = s['folder'].strip('/')
    with _locked(user):
        state = ndlib.read_json(_state_path(user)) or {'files': {}}
        progress = Progress(user)
        progress.data['folder'] = folder
        done = 0
        try:
            for _ in range(10):   # files that finish while we upload: another pass
                todo = _todo(user, state)
                if not todo:
                    break
                if done == 0:
                    _ensure_folder(creds, uid, folder)
                for name, size, mtime, known in todo:
                    entry = progress.item(name, size)
                    local = os.path.join(_downloads_dir(user), name)
                    overwrite = bool(known)   # this computer's own earlier upload of the file
                    remote = known['remote'] if known else name
                    try:
                        if size > CHUNK:
                            remote = _put_chunked(creds, uid, user, local, size, folder, remote, overwrite,
                                                  entry, progress)
                        else:
                            remote = _put_small(creds, uid, user, local, folder, remote, overwrite)
                    except FileNotFoundError:
                        entry['state'] = 'skipped'   # removed or changed meanwhile: the next run
                        continue
                    entry.update(done=size, state='done', remote=f'{folder}/{remote}')
                    state['files'][name] = {'size': size, 'mtime': mtime, 'remote': remote,
                                            'uploaded_at': int(time.time())}
                    ndlib.write_private_json(_state_path(user), state)
                    progress.write(True)
                    done += 1
        except (Offline, ndlib.ApiError) as e:
            progress.data['error'] = 'offline' if isinstance(e, Offline) else f'HTTP {e.status}'
            for entry in progress.data['items']:
                if entry['state'] == 'moving':
                    entry['state'] = 'failed'
            if progress.data['items']:
                progress.write(True)
            raise
        if progress.data['items']:
            progress.write(True)
        return f'{done} file(s) moved to {folder}' if done else 'nothing new'


def cleanup(user, at_signout=False, wait=True):
    """Removes local copies that are safely in Nextcloud and unchanged: keep_local_days after the
    upload, or at sign-out with 0. Forgets files that are gone locally. wait=False: 'busy' while
    an upload runs (the next run cleans up)."""
    try:
        with _locked(user, wait):
            return _cleanup(user, at_signout, settings()['keep_local_days'])
    except Busy:
        return 'busy'


def _cleanup(user, at_signout, keep):
    state = ndlib.read_json(_state_path(user)) or {'files': {}}
    local = list_local(user)
    removed = 0
    for name, known in list(state['files'].items()):
        if name not in local:
            del state['files'][name]
            continue
        if local[name] != (known['size'], known['mtime']):
            continue   # changed since the upload: upload() takes it first
        due = at_signout if keep == 0 else time.time() - known['uploaded_at'] > keep * 86400
        if due:
            path = os.path.join(_downloads_dir(user), name)
            if ndlib.as_user(user, ['/bin/rm', '-f', '--', path]).returncode == 0:
                del state['files'][name]
                removed += 1
    ndlib.write_private_json(_state_path(user), state)
    return f'{removed} local copy(ies) removed' if removed else 'nothing to remove'
