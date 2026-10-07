"""Wi-Fi on the NextDesk login screen (NetworkManager through libnm).

A network button (current state: wired / Wi-Fi signal / offline) and two pages for the greeter's
stack: the network list and a password page. Networks joined here are system connections (every
user, at boot), like ChromeOS's shared networks. polkit lets the lightdm user scan, connect, add
system connections and turn Wi-Fi on (/usr/share/polkit-1/rules.d/60-nextdesk-greeter.rules).

The password goes to NetworkManager over D-Bus, never on a command line. Enterprise (802.1X)
and WEP networks are listed but not joined here: that needs the desktop's network settings.
"""

import gi

gi.require_version('Gtk', '3.0')
gi.require_version('NM', '1.0')
from gi.repository import GLib, Gtk, NM  # noqa: E402

AP_FLAGS = getattr(NM, '80211ApFlags')
AP_SEC = getattr(NM, '80211ApSecurityFlags')
CONNECT_TIMEOUT = 45


def ssid_of(ap):
    ssid = ap.get_ssid()
    return NM.utils_ssid_to_utf8(ssid.get_data()) if ssid else ''


def security_of(ap):
    """'open', 'psk', 'sae', 'enterprise' or 'wep'."""
    wpa, rsn = ap.get_wpa_flags(), ap.get_rsn_flags()
    both = wpa | rsn
    if both & AP_SEC.KEY_MGMT_802_1X:
        return 'enterprise'
    if both & AP_SEC.KEY_MGMT_PSK:
        return 'psk'
    if rsn & AP_SEC.KEY_MGMT_SAE:
        return 'sae'
    if ap.get_flags() & AP_FLAGS.PRIVACY:
        return 'wep'
    return 'open'


def signal_icon(strength):
    level = 'excellent' if strength > 75 else 'good' if strength > 50 else 'ok' if strength > 25 else 'weak'
    return f'network-wireless-signal-{level}-symbolic'


class Wifi:
    def __init__(self, stack, label_factory, show_home):
        self.client = NM.Client.new(None)
        self.stack = stack
        self.label = label_factory
        self.show_home = show_home
        self.chosen = None          # access point waiting for a password
        self.activating = None      # (active connection, ssid, created connection or None)

        self.icon = Gtk.Image()
        self.button = Gtk.Button()
        self.button.add(self.icon)
        self.button.get_style_context().add_class('power')
        self.button.connect('clicked', lambda _b: self.open())
        for prop in ('primary-connection', 'state', 'wireless-enabled'):
            self.client.connect(f'notify::{prop}', lambda *_a: self.update_icon())
        self.update_icon()
        GLib.timeout_add_seconds(10, self._tick)

        stack.add_named(self.build_list(), 'wifi')
        stack.add_named(self.build_password(), 'wifipass')

    # --- State --------------------------------------------------------------------------------

    def device(self):
        for dev in self.client.get_devices():
            if dev.get_device_type() == NM.DeviceType.WIFI and dev.get_managed():
                return dev
        return None

    def update_icon(self):
        primary = self.client.get_primary_connection()
        name, icon = 'Not connected', 'network-offline-symbolic'
        if primary is not None:
            name = primary.get_id()
            if primary.get_connection_type() == '802-11-wireless':
                dev = self.device()
                ap = dev.get_active_access_point() if dev else None
                icon = signal_icon(ap.get_strength() if ap else 0)
            else:
                icon = 'network-wired-symbolic'
        elif self.device() is not None:
            # Connected to Wi-Fi that isn't the default route (no internet, captive portal, ...)
            # still shows the Wi-Fi signal.
            dev = self.device()
            ac = dev.get_active_connection()
            ap = dev.get_active_access_point()
            if ac is not None and ac.get_state() == NM.ActiveConnectionState.ACTIVATED and ap is not None:
                name, icon = f'{ac.get_id()} (no internet)', signal_icon(ap.get_strength())
            else:
                icon = 'network-wireless-offline-symbolic'
        self.icon.set_from_icon_name(icon, Gtk.IconSize.LARGE_TOOLBAR)
        self.button.set_tooltip_text(f'Network: {name}')

    def _tick(self):
        self.update_icon()
        if self.stack.get_visible_child_name() == 'wifi':
            self.refresh()
        return True

    # --- Pages --------------------------------------------------------------------------------

    def build_list(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_size_request(380, -1)
        box.add(self.label('Wi-Fi', 'title'))
        self.list_status = self.label(css='hint', wrap=True)
        box.add(self.list_status)
        self.enable_button = Gtk.Button(label='Turn on Wi-Fi')
        self.enable_button.get_style_context().add_class('primary')
        self.enable_button.connect('clicked', lambda _b: self.enable())
        box.add(self.enable_button)
        scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroll.set_min_content_height(280)
        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.NONE)
        self.listbox.connect('row-activated', lambda _l, row: self.choose(row.ap))
        scroll.add(self.listbox)
        box.add(scroll)
        back = Gtk.Button(label='Back')
        back.get_style_context().add_class('link')
        back.connect('clicked', lambda _b: self.show_home())
        box.add(back)
        return box

    def build_password(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_size_request(380, -1)
        self.pass_title = self.label(css='title', wrap=True)
        box.add(self.pass_title)
        self.pass_entry = Gtk.Entry(placeholder_text='Wi-Fi password', visibility=False)
        self.pass_entry.connect('activate', lambda _e: self.connect_chosen())
        box.add(self.pass_entry)
        show = Gtk.CheckButton(label='Show password')
        show.connect('toggled', lambda b: self.pass_entry.set_visibility(b.get_active()))
        box.add(show)
        go = Gtk.Button(label='Connect')
        go.get_style_context().add_class('primary')
        go.connect('clicked', lambda _b: self.connect_chosen())
        box.add(go)
        self.pass_status = self.label(css='error', wrap=True)
        box.add(self.pass_status)
        back = Gtk.Button(label='Back')
        back.get_style_context().add_class('link')
        back.connect('clicked', lambda _b: self.open())
        box.add(back)
        return box

    def open(self, message=''):
        self.stack.set_visible_child_name('wifi')
        self.refresh(message)
        dev = self.device()
        if dev is not None and self.client.wireless_get_enabled():
            dev.request_scan_async(None, self._scan_done, None)

    def _scan_done(self, dev, result, _data):
        try:
            dev.request_scan_finish(result)
        except GLib.Error:
            pass   # "scanning not allowed" right after a previous scan: the list is recent anyway
        GLib.timeout_add_seconds(3, lambda: self.refresh() and False)

    def refresh(self, message=None):
        dev = self.device()
        enabled = self.client.wireless_get_enabled()
        self.enable_button.set_visible(dev is not None and not enabled)
        if message is not None:
            self.list_status.set_text(message)
        if dev is None or not enabled:
            self.list_status.set_text('No Wi-Fi on this computer.' if dev is None else 'Wi-Fi is off.')
            self.show_rows([])
            return True

        active = dev.get_active_access_point()
        active_ssid = ssid_of(active) if active else None
        best = {}
        for ap in dev.get_access_points():
            ssid = ssid_of(ap)
            if ssid and (ssid not in best or ap.get_strength() > best[ssid].get_strength()):
                best[ssid] = ap
        if not best and not message:
            self.list_status.set_text('Looking for networks…')
        self.show_rows([(ssid, ap, ssid == active_ssid) for ssid, ap in
                        sorted(best.items(), key=lambda kv: (kv[0] != active_ssid, -kv[1].get_strength()))])
        return True

    def show_rows(self, entries):
        """Rebuilds the list only when what it shows changes, so it doesn't flicker and a click
        never lands on a row that's being replaced; otherwise just points the rows at the
        current access points."""
        shown = [(ssid, signal_icon(ap.get_strength()), security_of(ap) != 'open', connected)
                 for ssid, ap, connected in entries]
        rows = self.listbox.get_children()
        if shown == getattr(self, '_shown', None) and len(rows) == len(entries):
            for row, (_ssid, ap, _connected) in zip(rows, entries):
                row.ap = ap
            return
        self._shown = shown
        for row in rows:
            self.listbox.remove(row)
        for (ssid, icon, secured, connected), (_s, ap, _c) in zip(shown, entries):
            row = Gtk.ListBoxRow()
            row.ap = ap
            line = Gtk.Box(spacing=10, margin=8)
            line.add(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU))
            name = self.label(ssid + ('  (connected)' if connected else ''))
            name.set_xalign(0)
            line.pack_start(name, True, True, 0)
            if secured:
                line.add(Gtk.Image.new_from_icon_name('network-wireless-encrypted-symbolic', Gtk.IconSize.MENU))
            row.add(line)
            self.listbox.add(row)
        self.listbox.show_all()

    # --- Connecting ---------------------------------------------------------------------------

    def enable(self):
        self.client.dbus_set_property(NM.DBUS_PATH, NM.DBUS_INTERFACE, 'WirelessEnabled',
                                      GLib.Variant('b', True), -1, None, None, None)
        GLib.timeout_add_seconds(2, lambda: self.open() and False)

    def existing_connection(self, ssid):
        for conn in self.client.get_connections():
            s = conn.get_setting_wireless()
            if s is not None and s.get_ssid() is not None and NM.utils_ssid_to_utf8(s.get_ssid().get_data()) == ssid:
                return conn
        return None

    def choose(self, ap):
        ssid, security = ssid_of(ap), security_of(ap)
        if security in ('enterprise', 'wep'):
            self.list_status.set_text(f'{ssid} needs an organisation login (or uses old WEP security). '
                                      'Connect to it from the desktop after signing in.')
            return
        conn = self.existing_connection(ssid)
        if conn is not None:
            self.list_status.set_text(f'Connecting to {ssid}…')
            self.client.activate_connection_async(conn, self.device(), ap.get_path(), None, self._activated,
                                                  (ssid, None))
            return
        if security == 'open':
            self.connect(ap, None)
            return
        self.chosen = ap
        self.pass_title.set_text(ssid)
        self.pass_entry.set_text('')
        self.pass_status.set_text('')
        self.stack.set_visible_child_name('wifipass')
        self.pass_entry.grab_focus()

    def connect_chosen(self):
        password = self.pass_entry.get_text()
        if len(password) < 8:
            self.pass_status.set_text('Wi-Fi passwords are at least 8 characters.')
            return
        self.connect(self.chosen, password)

    def connect(self, ap, password):
        ssid = ssid_of(ap)
        conn = NM.SimpleConnection.new()
        s_con = NM.SettingConnection.new()
        s_con.set_property(NM.SETTING_CONNECTION_ID, ssid)
        s_con.set_property(NM.SETTING_CONNECTION_UUID, NM.utils_uuid_generate())
        s_con.set_property(NM.SETTING_CONNECTION_TYPE, '802-11-wireless')
        s_con.set_property(NM.SETTING_CONNECTION_AUTOCONNECT, True)
        conn.add_setting(s_con)
        s_wifi = NM.SettingWireless.new()
        s_wifi.set_property(NM.SETTING_WIRELESS_SSID, GLib.Bytes.new(ssid.encode()))
        conn.add_setting(s_wifi)
        if password is not None:
            s_sec = NM.SettingWirelessSecurity.new()
            s_sec.set_property(NM.SETTING_WIRELESS_SECURITY_KEY_MGMT, 'sae' if security_of(ap) == 'sae' else 'wpa-psk')
            s_sec.set_property(NM.SETTING_WIRELESS_SECURITY_PSK, password)
            conn.add_setting(s_sec)
        self.pass_entry.set_text('')
        self.stack.set_visible_child_name('wifi')
        self.list_status.set_text(f'Connecting to {ssid}…')
        self.client.add_and_activate_connection_async(conn, self.device(), ap.get_path(), None,
                                                      self._added, ssid)

    def _added(self, client, result, ssid):
        try:
            active = client.add_and_activate_connection_finish(result)
        except GLib.Error as e:
            self.list_status.set_text(f'Could not connect to {ssid}: {e.message}')
            return
        self._watch(active, ssid, created=True)

    def _activated(self, client, result, data):
        ssid, _ = data
        try:
            active = client.activate_connection_finish(result)
        except GLib.Error as e:
            self.list_status.set_text(f'Could not connect to {ssid}: {e.message}')
            return
        self._watch(active, ssid, created=False)

    def _watch(self, active, ssid, created):
        def on_state(*_a):
            state = active.get_state()
            if state == NM.ActiveConnectionState.ACTIVATED:
                self.update_icon()
                self.show_home()
                return
            if state in (NM.ActiveConnectionState.DEACTIVATED, NM.ActiveConnectionState.DEACTIVATING):
                self._failed(active, ssid, created)

        active.connect('notify::state', on_state)
        GLib.timeout_add_seconds(CONNECT_TIMEOUT, lambda: (active.get_state() != NM.ActiveConnectionState.ACTIVATED
                                                           and self._failed(active, ssid, created)) and False)
        on_state()

    def _failed(self, active, ssid, created):
        if getattr(active, 'nextdesk_failed', False):
            return
        active.nextdesk_failed = True
        conn = active.get_connection()
        if created and conn is not None:
            # Don't keep a saved network with a wrong password
            conn.delete_async(None, None, None)
        self.open(f'Could not connect to {ssid}. Check the password and try again.')
