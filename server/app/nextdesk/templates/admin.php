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
