/* NextDesk settings (Administration settings → Security): user policy and device policy.
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

        // Device policy URL
        const policyUrl = base + 'admin/device-policy?format=json';
        const policyMessage = (text, isError) => message(text, isError, 'nextdesk-device-policy-message');
        const showDevicePolicy = (state) => {
            $('nextdesk-device-policy').value = state.url;
            $('nextdesk-device-policy-per-hostname').checked = !!state.per_hostname;
            $('nextdesk-device-policy-departments').value = (state.departments || []).join('\n');
            $('nextdesk-device-policy-hostname-prefix').value = state.hostname_prefix || '';
        };
        $('nextdesk-device-policy-save').addEventListener('click', async () => {
            try {
                const state = await call('PUT', {
                    url: $('nextdesk-device-policy').value.trim(),
                    per_hostname: $('nextdesk-device-policy-per-hostname').checked,
                    departments: $('nextdesk-device-policy-departments').value,
                    hostname_prefix: $('nextdesk-device-policy-hostname-prefix').value.trim(),
                }, policyUrl);
                showDevicePolicy(state);
                policyMessage(state.url ? 'Saved.' : 'Saved (no device policy URL).');
            } catch (e) {
                policyMessage(e.message, true);
            }
        });
        try {
            showDevicePolicy(await call('GET', undefined, policyUrl));
        } catch (e) {
            policyMessage(e.message, true);
        }

        // Enrollment tokens: always valid for 24 hours, revocable
        const enrollUrl = base + 'admin/enrollment-tokens';
        const enrollMessage = (text, isError) => message(text, isError, 'nextdesk-enroll-message');
        const when = (t) => new Date(t * 1000).toLocaleString(undefined,
            {weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'});
        const showTokens = (tokens) => {
            const table = $('nextdesk-enroll-tokens');
            const body = table.querySelector('tbody');
            body.textContent = '';
            table.style.display = tokens.length ? '' : 'none';
            for (const t of tokens) {
                const tr = body.insertRow();
                for (const text of [when(t.created_at), t.created_by, when(t.expires_at), String(t.enrolled)]) {
                    tr.insertCell().textContent = text;
                }
                const revoke = document.createElement('button');
                revoke.textContent = 'Revoke';
                revoke.addEventListener('click', async () => {
                    try {
                        await call('DELETE', undefined, `${enrollUrl}/${t.id}?format=json`);
                        if (t.id === shownId) {
                            $('nextdesk-enroll-new').style.display = 'none';
                        }
                        showTokens((await call('GET', undefined, enrollUrl + '?format=json')).tokens);
                        enrollMessage('Revoked.');
                    } catch (e) {
                        enrollMessage(e.message, true);
                    }
                });
                tr.insertCell().appendChild(revoke);
            }
        };
        let shownId = null;
        $('nextdesk-enroll-create').addEventListener('click', async () => {
            try {
                const t = await call('POST', {}, enrollUrl + '?format=json');
                shownId = t.id;
                $('nextdesk-enroll-token').textContent = t.token;
                $('nextdesk-enroll-valid').textContent =
                    `Valid from now until ${when(t.expires_at)} (24 hours). It's shown only now.`;
                const file = JSON.stringify({nextcloud_url: t.server, enrollment_token: t.token,
                    expires_at: t.expires_at}, null, 2) + '\n';
                $('nextdesk-enroll-download').href = URL.createObjectURL(new Blob([file], {type: 'application/json'}));
                $('nextdesk-enroll-new').style.display = '';
                showTokens((await call('GET', undefined, enrollUrl + '?format=json')).tokens);
                enrollMessage('');
            } catch (e) {
                enrollMessage(e.message, true);
            }
        });
        try {
            showTokens((await call('GET', undefined, enrollUrl + '?format=json')).tokens);
        } catch (e) {
            enrollMessage(e.message, true);
        }
    });
})();
