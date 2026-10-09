<?php
/** @var \OCP\IL10N $l */
?>
<div id="nextdesk-computers" class="section">
    <h2>NextDesk computers</h2>
    <p class="settings-hint">
        Computers appear after their first sign-in with Nextcloud; after that they report in by
        themselves (every 15 minutes, also with nobody signed in). Showing a disk recovery key is
        logged. Administrators can give a group access to this page under Administration privileges.
    </p>
    <p>
        <input id="nextdesk-computers-search" type="search" placeholder="Search computer, machine id or user" style="width: 24em">
    </p>
    <table id="nextdesk-computers-table" class="grid" style="margin-bottom: 1em">
        <thead><tr>
            <th>Computer</th><th>Last contact</th><th>Last user</th><th>Device policy</th>
            <th>Version</th><th>Installed</th><th>Disk recovery key</th><th></th>
        </tr></thead>
        <tbody></tbody>
    </table>
    <p>
        <button id="nextdesk-computers-prev">Previous</button>
        <span id="nextdesk-computers-range" style="margin: 0 1em"></span>
        <button id="nextdesk-computers-next">Next</button>
    </p>
    <p id="nextdesk-computers-message" class="settings-hint"></p>
</div>
