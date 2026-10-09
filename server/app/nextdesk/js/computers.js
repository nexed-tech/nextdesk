/* NextDesk computers (Administration settings → NextDesk computers): search, paging, disk recovery
   keys. Uses the computers OCS API (administrators and delegated groups). */
(function () {
    'use strict';

    const base = OC.linkToOCS('apps/nextdesk/api/v1', 2) + 'computers';
    const PAGE = 50;
    const $ = (id) => document.getElementById(id);
    let offset = 0;
    let search = '';

    function message(text, isError) {
        const el = $('nextdesk-computers-message');
        el.textContent = text;
        el.style.color = isError ? 'var(--color-error)' : '';
    }

    async function call(method, path, params) {
        const url = new URL(base + path, window.location.origin);
        url.searchParams.set('format', 'json');
        for (const [k, v] of Object.entries(params || {})) {
            url.searchParams.set(k, v);
        }
        const response = await fetch(url, {
            method,
            headers: { 'OCS-APIRequest': 'true', 'requesttoken': OC.requestToken, 'Accept': 'application/json' },
        });
        const json = await response.json().catch(() => null);
        if (!response.ok || !json) {
            throw new Error((json && json.ocs && json.ocs.meta && json.ocs.meta.message) || response.statusText);
        }
        return json.ocs.data;
    }

    /** "5 min ago" ('' for none). */
    function ago(timestamp) {
        if (!timestamp) {
            return '';
        }
        const date = new Date(timestamp * 1000);
        const seconds = Math.max(0, (Date.now() - date) / 1000);
        return seconds < 60 ? 'just now'
            : seconds < 3600 ? `${Math.floor(seconds / 60)} min ago`
                : seconds < 86400 ? `${Math.floor(seconds / 3600)} h ago`
                    : seconds < 30 * 86400 ? `${Math.floor(seconds / 86400)} days ago`
                        : date.toLocaleDateString();
    }

    /** "5 min ago", with the full date and time as a tooltip. */
    function when(cell, timestamp) {
        cell.textContent = ago(timestamp) || '–';
        if (timestamp) {
            cell.title = new Date(timestamp * 1000).toLocaleString();
        }
    }

    function lines(cell, first, second, title) {
        cell.textContent = first;
        if (second) {
            const small = document.createElement('div');
            small.className = 'settings-hint';
            small.style.margin = '0';
            small.textContent = second;
            cell.appendChild(small);
        }
        if (title) {
            cell.title = title;
        }
    }

    async function load() {
        let page;
        try {
            page = await call('GET', '', { search, limit: PAGE, offset });
        } catch (e) {
            message(e.message, true);
            return;
        }
        message('');
        const body = $('nextdesk-computers-table').querySelector('tbody');
        body.textContent = '';
        if (page.computers.length === 0) {
            const td = body.insertRow().insertCell();
            td.colSpan = 8;
            td.textContent = search ? 'No computers match.' : 'No computers have reported in yet.';
        }
        for (const c of page.computers) {
            const tr = body.insertRow();
            lines(tr.insertCell(), c.hostname || '(no name)', c.machine_id);
            when(tr.insertCell(), c.last_contact);
            lines(tr.insertCell(), c.user_id || '–', ago(c.user_seen_at),
                c.user_seen_at ? new Date(c.user_seen_at * 1000).toLocaleString() : '');
            const policy = tr.insertCell();
            if (c.policy) {
                lines(policy, c.policy.name, c.policy.applied_at
                    ? 'applied ' + new Date(c.policy.applied_at * 1000).toLocaleString() : '',
                `serial ${c.policy.serial}\n${c.policy.source}`);
            } else {
                policy.textContent = '–';
            }
            tr.insertCell().textContent = c.version || '–';
            const installed = tr.insertCell();
            installed.textContent = c.installed_at ? new Date(c.installed_at * 1000).toLocaleDateString() : '–';
            const keyCell = tr.insertCell();
            keyCell.style.fontFamily = 'monospace';
            if (c.has_key) {
                const show = document.createElement('button');
                show.textContent = 'Show';
                show.title = 'Shows the key; this is logged';
                show.addEventListener('click', async () => {
                    try {
                        keyCell.textContent = (await call('GET', '/' + c.machine_id + '/recovery-key')).recovery_key;
                    } catch (e) {
                        message(e.message, true);
                    }
                });
                keyCell.appendChild(show);
            } else {
                keyCell.textContent = '–';
            }
            const actions = tr.insertCell();
            if (page.can_delete) {
                const remove = document.createElement('button');
                remove.textContent = 'Delete';
                remove.addEventListener('click', async () => {
                    if (!confirm(`Delete ${c.hostname || c.machine_id} and its recovery key? Only do this for a computer that no longer exists.`)) {
                        return;
                    }
                    try {
                        await call('DELETE', '/' + c.machine_id);
                        await load();
                        message('Deleted.');
                    } catch (e) {
                        message(e.message, true);
                    }
                });
                actions.appendChild(remove);
            }
        }
        const last = Math.min(offset + PAGE, page.total);
        $('nextdesk-computers-range').textContent = page.total ? `${offset + 1}–${last} of ${page.total}` : '';
        $('nextdesk-computers-prev').disabled = offset === 0;
        $('nextdesk-computers-next').disabled = last >= page.total;
    }

    document.addEventListener('DOMContentLoaded', () => {
        let timer = null;
        $('nextdesk-computers-search').addEventListener('input', (event) => {
            clearTimeout(timer);
            timer = setTimeout(() => {
                search = event.target.value.trim();
                offset = 0;
                load();
            }, 300);
        });
        $('nextdesk-computers-prev').addEventListener('click', () => {
            offset = Math.max(0, offset - PAGE);
            load();
        });
        $('nextdesk-computers-next').addEventListener('click', () => {
            offset += PAGE;
            load();
        });
        load();
    });
})();
