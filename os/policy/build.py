#!/usr/bin/env python3
"""Publishes the device policies in policies/ to the apt repository site (repo.nexed.tech).

  python3 os/policy/build.py SITE_DIR [BASE_URL]      (needs python3-yaml, git, gpg)

For every policies/<name>.yaml: validate strictly (an invalid file fails the build, so it's never
published), add name and serial (the file's last commit time: a machine only applies a newer
serial), write SITE_DIR/policy/<name>.json and sign it (<name>.json.asc, the default gpg key: the
apt repository key in the workflow). policies/index.yaml (Nextcloud URL -> policy name) becomes
policy/index.json (Nextcloud URL -> policy URL), also signed. Policies removed from the repository
are removed from the site.
"""

import json
import os
import subprocess
import sys

import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'os', 'package', 'root', 'usr', 'lib', 'nextdesk'))
import ndpolicy  # noqa: E402

SRC = os.path.join(REPO, 'policies')


def commit_time(path):
    out = subprocess.run(['git', '-C', REPO, 'log', '-1', '--format=%ct', '--', path],
                         capture_output=True, text=True, check=True).stdout.strip()
    if not out:
        sys.exit(f'E: {path} is not committed (the serial is its commit time)')
    return int(out)


def write_signed(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write('\n')
    subprocess.run(['gpg', '--batch', '--yes', '--armor', '--detach-sign', '-o', path + '.asc', path], check=True)


def main():
    site = sys.argv[1]
    base = (sys.argv[2] if len(sys.argv) > 2 else 'https://repo.nexed.tech').rstrip('/')
    out = os.path.join(site, 'policy')
    os.makedirs(out, exist_ok=True)

    names = []
    for file in sorted(os.listdir(SRC)):
        if not file.endswith('.yaml') or file == 'index.yaml':
            continue
        name = file[:-len('.yaml')]
        path = os.path.join(SRC, file)
        with open(path, encoding='utf-8') as f:
            policy = yaml.safe_load(f) or {}
        if 'serial' in policy or 'name' in policy:
            sys.exit(f'E: {file}: serial and name are added when publishing; remove them')
        policy['name'] = name
        policy['serial'] = commit_time(path)
        try:
            policy, _ = ndpolicy.validate(policy, strict=True)
        except ndpolicy.PolicyError as e:
            sys.exit(f'E: {file}: {e}')
        write_signed(os.path.join(out, f'{name}.json'), policy)
        names.append(name)
        print(f'policy {name}: serial {policy["serial"]}')

    index = {}
    index_path = os.path.join(SRC, 'index.yaml')
    if os.path.exists(index_path):
        with open(index_path, encoding='utf-8') as f:
            for nc_url, name in (yaml.safe_load(f) or {}).items():
                if name not in names:
                    sys.exit(f'E: index.yaml: {nc_url} points to {name}, which has no policies/{name}.yaml')
                index[nc_url.rstrip('/')] = f'{base}/policy/{name}.json'
    write_signed(os.path.join(out, 'index.json'), index)

    for file in os.listdir(out):
        stem = file.split('.')[0]
        if stem != 'index' and stem not in names:
            os.remove(os.path.join(out, file))
            print(f'removed {file}')


if __name__ == '__main__':
    main()
