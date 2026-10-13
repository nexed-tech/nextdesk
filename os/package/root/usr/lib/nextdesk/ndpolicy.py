"""NextDesk device policy: the schema, shared by the publishing workflow (os/policy/build.py,
strict) and the machines (nextdesk-policy, lenient).

A policy is a JSON object (YAML in the repository's policies/ directory):

  serial         int, added when publishing (commit time): a machine only applies a newer one
  name           str, added when publishing (the file name)
  nextcloud      url (https), apps (list of APPS)
  url_change     logout_at ("YYYY-MM-DD HH:MM", local time), warn_minutes: a forced logout so a
                 Nextcloud URL change applies sooner than the next sign-in
  session        logout_at ("HH:MM", daily), warn_minutes
  screen_lock    after_minutes, on_suspend, enforced
  wallpaper      url (https), sha256
  updates        automatic (unattended-upgrades: Debian, security, NextDesk, Chrome), time
                 ("HH:MM", daily, default 03:00), reboot_at ("HH:MM": reboot when an update needs
                 it, only with nobody signed in)
  printers       a list of {name, uri (ipp:// or ipps://), description, location, default}:
                 driverless print queues added on every machine (others on the network are
                 found on their own)
  downloads      sync (default true: new files in ~/Downloads go to the user's Nextcloud),
                 folder (default "Downloads"), keep_local_days (default 7; 0 = at sign-out)
  packages       debian, security (mirror URLs replacing deb.debian.org / security.debian.org),
                 proxy (apt proxy, e.g. apt-cacher-ng), nextdesk (a mirror of repo.nexed.tech: test
                 a release, then refresh the mirror to roll it out)

Strict (publishing): unknown keys are errors, so typos never reach machines. Lenient (machines):
unknown keys are reported and ignored, so an older machine still applies a newer policy's known
parts.
"""

import re

APPS = ('Calendar', 'Contacts', 'Files', 'Mail', 'Notes', 'Office', 'Photos', 'Talk', 'Tasks', 'Deck', 'Forms', 'News')


class PolicyError(ValueError):
    pass


def _https_url(v):
    return isinstance(v, str) and re.fullmatch(r'https://[A-Za-z0-9.-]+(:\d+)?(/[^\s]*)?', v) is not None


def _http_url(v):
    """http allowed: for package mirrors and proxies (apt checks the packages' signatures)."""
    return isinstance(v, str) and re.fullmatch(r'https?://[A-Za-z0-9.-]+(:\d+)?(/[^\s"]*)?', v) is not None


def _int(lo, hi):
    return lambda v: isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def _apps(v):
    return isinstance(v, list) and v != [] and all(a in APPS for a in v) and len(set(v)) == len(v)


def _time(v):
    return isinstance(v, str) and re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', v) is not None


def _datetime(v):
    return isinstance(v, str) and re.fullmatch(r'\d{4}-\d\d-\d\d ([01]\d|2[0-3]):[0-5]\d', v) is not None


def _bool(v):
    return isinstance(v, bool)


PRINTER_KEYS = {'name', 'uri', 'description', 'location', 'default'}


def _printers(v):
    """A list of driverless printers; CUPS queue names are letters, digits, - and _."""
    if not isinstance(v, list) or len(v) > 50:
        return False
    names = set()
    for p in v:
        if not (isinstance(p, dict) and set(p) <= PRINTER_KEYS and 'name' in p and 'uri' in p):
            return False
        if not (isinstance(p['name'], str) and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', p['name'])):
            return False
        if not (isinstance(p['uri'], str) and re.fullmatch(r'ipps?://[A-Za-z0-9.-]+(:\d+)?(/[^\s"]*)?', p['uri'])):
            return False
        if any(not (isinstance(p.get(k, ''), str) and len(p.get(k, '')) <= 127 and p.get(k, '').isprintable())
               for k in ('description', 'location')):
            return False
        if not isinstance(p.get('default', False), bool) or p['name'].lower() in names:
            return False
        names.add(p['name'].lower())
    return sum(1 for p in v if p.get('default')) <= 1


def _folder(v):
    """A folder in the user's files: no leading /, no . or .. parts, no backslashes."""
    return (isinstance(v, str) and 0 < len(v) <= 200 and v.isprintable() and '\\' not in v and not v.startswith('/')
            and all(part not in ('', '.', '..') for part in v.split('/')))


# section -> {key: (check, description)}; None = a top-level scalar
SCHEMA = {
    'serial': (_int(0, 2**63 - 1), 'a positive integer'),
    'name': (lambda v: isinstance(v, str) and re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', v), 'a policy name'),
    'nextcloud': {
        'url': (_https_url, 'an https:// URL'),
        'apps': (_apps, f'a list of: {", ".join(APPS)}'),
    },
    'url_change': {
        'logout_at': (_datetime, '"YYYY-MM-DD HH:MM"'),
        'warn_minutes': (_int(1, 120), '1 to 120'),
    },
    'session': {
        'logout_at': (_time, '"HH:MM"'),
        'warn_minutes': (_int(1, 120), '1 to 120'),
    },
    'screen_lock': {
        'after_minutes': (_int(0, 240), '0 (never) to 240'),
        'on_suspend': (_bool, 'true or false'),
        'enforced': (_bool, 'true or false'),
    },
    'wallpaper': {
        'url': (_https_url, 'an https:// URL'),
        'sha256': (lambda v: isinstance(v, str) and re.fullmatch(r'[0-9a-f]{64}', v), '64 hex characters'),
    },
    'updates': {
        'automatic': (_bool, 'true or false'),
        'time': (_time, '"HH:MM"'),
        'reboot_at': (_time, '"HH:MM"'),
    },
    'printers': (_printers, 'a list of printers: name (letters, digits, - and _), uri (ipp:// or ipps://), '
                 'optional description, location, default (at most one)'),
    'downloads': {
        'sync': (_bool, 'true or false'),
        'folder': (_folder, 'a folder in the user\'s files, e.g. "Downloads" or "Work/Downloads"'),
        'keep_local_days': (_int(0, 365), '0 (remove at sign-out) to 365'),
    },
    'packages': {
        'debian': (_http_url, 'an http:// or https:// URL'),
        'security': (_http_url, 'an http:// or https:// URL'),
        'proxy': (_http_url, 'an http:// or https:// URL'),
        'nextdesk': (_http_url, 'an http:// or https:// URL'),
    },
}

REQUIRED = {'wallpaper': ('url', 'sha256'), 'url_change': ('logout_at',), 'session': ('logout_at',),
            'updates': ('automatic',)}


def validate(policy, strict=True):
    """The policy with only known, valid keys, and a list of warnings (lenient mode). Raises
    PolicyError for invalid values, and in strict mode for unknown keys too."""
    if not isinstance(policy, dict):
        raise PolicyError('a policy is a mapping (key: value)')
    clean, warnings = {}, []

    def unknown(where):
        if strict:
            raise PolicyError(f'unknown key: {where}')
        warnings.append(f'ignored unknown key: {where}')

    for key, value in policy.items():
        spec = SCHEMA.get(key)
        if spec is None:
            unknown(key)
        elif isinstance(spec, tuple):
            if not spec[0](value):
                raise PolicyError(f'{key}: must be {spec[1]}')
            clean[key] = value
        else:
            if not isinstance(value, dict):
                raise PolicyError(f'{key}: must be a mapping')
            section = {}
            for k, v in value.items():
                if k not in spec:
                    unknown(f'{key}.{k}')
                    continue
                if not spec[k][0](v):
                    raise PolicyError(f'{key}.{k}: must be {spec[k][1]}')
                section[k] = v
            for k in REQUIRED.get(key, ()):
                if k not in section:
                    raise PolicyError(f'{key}.{k} is required')
            clean[key] = section
    if 'url_change' in clean and 'url' not in clean.get('nextcloud', {}):
        raise PolicyError('url_change needs nextcloud.url')
    return clean, warnings
