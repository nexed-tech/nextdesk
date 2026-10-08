/* NextDesk settings (Administration settings → Security): policy and disk recovery keys.
   Uses the admin OCS API. */
(function () {
    'use strict';

    const base = OC.linkToOCS('apps/nextdesk/api/v1', 2);
    const url = base + 'admin/policy?format=json';
    const key = 'offline_grace_days';
    const $ = (id) => document.getElementById(id);

    function message(text, isError, id = 'nextdesk-message') {
        const el = $(id);
        el.textContent = text;
        el.style.color = isError ? 'var(--color-error)' : '';
    }

    async function call(method, body, target = url) {
        const response = await fetch(target, {
            method,
            headers: {
                'OCS-APIRequest': 'true',
                'requesttoken': OC.requestToken,
                'Content-Type': 'application/json',
                'Accept': 'application/json',
            },
            body: body ? JSON.stringify(body) : undefined,
        });
        const json = await response.json().catch(() => null);
        if (!response.ok || !json) {
            throw new Error((json && json.ocs && json.ocs.meta && json.ocs.meta.message) || response.statusText);
        }
        return json.ocs.data;
    }

    function render(state) {
        $('nextdesk-global-grace').value = state.global[key] ?? '';
        $('nextdesk-global-grace').placeholder = state.defaults[key];

        const body = $('nextdesk-overrides').querySelector('tbody');
        body.textContent = '';
        const rows = [
            ...Object.entries(state.groups).map(([id, policy]) => ['group', id, policy]),
            ...Object.entries(state.users).map(([id, policy]) => ['user', id, policy]),
        ];
        if (rows.length === 0) {
            const tr = body.insertRow();
            const td = tr.insertCell();
            td.colSpan = 4;
            td.textContent = 'No overrides.';
        }
        for (const [scope, id, policy] of rows) {
            const tr = body.insertRow();
            tr.insertCell().textContent = scope === 'group' ? 'Group' : 'User';
            tr.insertCell().textContent = id;
            tr.insertCell().textContent = policy[key] ?? '';
            const remove = document.createElement('button');
            remove.textContent = 'Remove';
            remove.addEventListener('click', () => save({ scope, id, policy: null }));
            tr.insertCell().appendChild(remove);
        }
    }

    // --- Disk recovery keys ---

    const keysUrl = (device) => base + 'admin/recovery-keys' + (device ? '/' + encodeURIComponent(device) : '') + '?format=json';
    const recoveryMessage = (text, isError) => message(text, isError, 'nextdesk-recovery-message');

    async function loadRecoveryKeys() {
        const devices = await call('GET', undefined, keysUrl());
        const body = $('nextdesk-recovery-keys').querySelector('tbody');
        body.textContent = '';
        if (devices.length === 0) {
            const td = body.insertRow().insertCell();
            td.colSpan = 6;
            td.textContent = 'No devices with an encrypted disk have stored a key yet.';
        }
        for (const d of devices) {
            const tr = body.insertRow();
            tr.insertCell().textContent = d.hostname;
            tr.insertCell().textContent = d.machine_id;
            tr.insertCell().textContent = d.user_id;
            tr.insertCell().textContent = new Date(d.updated_at * 1000).toLocaleString();
            const keyCell = tr.insertCell();
            keyCell.style.fontFamily = 'monospace';
            const show = document.createElement('button');
            show.textContent = 'Show';
            show.addEventListener('click', async () => {
                try {
                    const [found] = await call('GET', undefined, keysUrl(d.machine_id));
                    keyCell.textContent = found.recovery_key;
                } catch (e) {
                    recoveryMessage(e.message, true);
                }
            });
            keyCell.appendChild(show);
            const remove = document.createElement('button');
            remove.textContent = 'Delete';
            remove.addEventListener('click', async () => {
                if (!confirm(`Delete the recovery key of ${d.hostname}? Only do this for a device that no longer exists.`)) {
                    return;
                }
                try {
                    await call('DELETE', undefined, keysUrl(d.machine_id));
                    await loadRecoveryKeys();
                    recoveryMessage('Deleted.');
                } catch (e) {
                    recoveryMessage(e.message, true);
                }
            });
            tr.insertCell().appendChild(remove);
        }
    }

    async function save(body) {
        try {
            render(await call('PUT', body));
            message('Saved.');
        } catch (e) {
            message(e.message, true);
        }
    }

    document.addEventListener('DOMContentLoaded', async () => {
        if (!$('nextdesk-admin')) {
            return;
        }
        $('nextdesk-global-save').addEventListener('click', () => {
            const value = $('nextdesk-global-grace').value;
            save({ scope: 'global', id: '', policy: value === '' ? null : { [key]: Number(value) } });
        });
        $('nextdesk-new-add').addEventListener('click', () => {
            const id = $('nextdesk-new-id').value.trim();
            const value = $('nextdesk-new-grace').value;
            if (id === '' || value === '') {
                message('Fill in an id and a number of days.', true);
                return;
            }
            save({ scope: $('nextdesk-new-scope').value, id, policy: { [key]: Number(value) } });
        });
        try {
            render(await call('GET'));
        } catch (e) {
            message(e.message, true);
        }
        try {
            await loadRecoveryKeys();
        } catch (e) {
            recoveryMessage(e.message, true);
        }
    });
})();
