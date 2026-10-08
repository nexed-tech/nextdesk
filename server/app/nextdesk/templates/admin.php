<?php
/** @var \OCP\IL10N $l */
?>
<div id="nextdesk-admin" class="section">
    <h2>NextDesk</h2>
    <p class="settings-hint">
        Policy for NextDesk OS devices. Group overrides replace the global value; when a user is in
        several groups, the strictest value applies. A user override applies to that user only.
        Devices pick up changes at their next online check.
    </p>

    <h3>Device policy</h3>
    <p class="settings-hint">
        The signed NextDesk device policy for this server's machines (Nextcloud apps, updates,
        package sources, ...). Machines pick up a change within 15 minutes; the installer uses it
        right away. Empty: machines keep their own setting.
    </p>
    <p>
        <input id="nextdesk-device-policy" type="url" placeholder="https://repo.nexed.tech/policy/example.json" style="width: 32em">
    </p>
    <p>
        <input id="nextdesk-device-policy-per-hostname" type="checkbox" class="checkbox">
        <label for="nextdesk-device-policy-per-hostname">Policy per hostname group</label>
    </p>
    <p class="settings-hint">
        Machines then look for a policy named after the part of their computer name before the
        first "-", next to the file above: <code>sales-001</code> gets <code>sales.json</code>. The file
        above is the fallback (no "-" in the name, or no such file).
    </p>
    <p>
        <label for="nextdesk-device-policy-departments">Departments (one per line; lowercase letters and digits)</label><br>
        <textarea id="nextdesk-device-policy-departments" rows="4" style="width: 20em" placeholder="sales&#10;helpdesk"></textarea>
    </p>
    <p class="settings-hint">
        The installer offers these and proposes a computer name like <code>sales-F5D411</code>, so with
        policies per hostname group the machine gets <code>sales.json</code>.
    </p>
    <p>
        <button id="nextdesk-device-policy-save" class="primary">Save</button>
    </p>
    <p id="nextdesk-device-policy-message" class="settings-hint"></p>

    <h3>Global</h3>
    <p>
        <label for="nextdesk-global-grace">Offline login allowed for (days since the device last reached this server; 0 = never)</label><br>
        <input id="nextdesk-global-grace" type="number" min="0" max="3650" style="width: 8em">
        <button id="nextdesk-global-save" class="primary">Save</button>
    </p>

    <h3>Overrides</h3>
    <table id="nextdesk-overrides" class="grid" style="margin-bottom: 1em">
        <thead><tr><th>Type</th><th>Group / user id</th><th>Offline days</th><th></th></tr></thead>
        <tbody></tbody>
    </table>
    <p>
        <select id="nextdesk-new-scope">
            <option value="group">Group</option>
            <option value="user">User</option>
        </select>
        <input id="nextdesk-new-id" type="text" placeholder="Group or user id">
        <input id="nextdesk-new-grace" type="number" min="0" max="3650" placeholder="Days" style="width: 6em">
        <button id="nextdesk-new-add">Add override</button>
    </p>
    <p id="nextdesk-message" class="settings-hint"></p>

    <h3>Disk recovery keys</h3>
    <p class="settings-hint">
        Encrypted NextDesk devices store their disk recovery key here at the first sign-in (and when
        one is replaced with <code>nextdesk-recovery-key --new</code>). Showing a key is logged.
    </p>
    <table id="nextdesk-recovery-keys" class="grid" style="margin-bottom: 1em">
        <thead><tr><th>Computer</th><th>Machine id</th><th>Sent by</th><th>Updated</th><th>Recovery key</th><th></th></tr></thead>
        <tbody></tbody>
    </table>
    <p id="nextdesk-recovery-message" class="settings-hint"></p>
</div>
