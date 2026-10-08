#!/usr/bin/env bash
#
# Renders the installer medium's boot menu branding (GRUB for UEFI and BIOS, isolinux for BIOS)
# into os/iso/config/bootloaders/. The outputs are committed, so building the ISO needs no
# renderer; run this after changing the logo or the layout.
#
#   bash os/iso/branding/render.sh    (Debian: apt install librsvg2-bin fonts-inter grub-common)
#
# The logo is the NextDesk OS lockup (design 1a without the desk bar, as on the login screen):
# the marks in os/package/root/usr/share/nextdesk/.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
mark="$repo/os/package/root/usr/share/nextdesk/nextdesk-mark.svg"
grub="$repo/os/iso/config/bootloaders/grub-pc"
isolinux="$repo/os/iso/config/bootloaders/isolinux"
mkdir -p "$grub/live-theme" "$isolinux"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The mark as a data URI, so one SVG holds the whole lockup
mark_uri="data:image/svg+xml;base64,$(base64 -w0 "$mark")"

# Lockup: N (86x96 design units) + NextDesk / OS, 22 apart (white text: dark backgrounds)
lockup() {   # lockup FILE: the lockup alone, transparent
    cat > "$1" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="290" height="96">
  <image x="0" y="0" width="86" height="96" xlink:href="$mark_uri"/>
  <text x="108" y="52" font-family="Inter" font-weight="700" font-size="40" letter-spacing="-1.2" fill="#FFFFFF">NextDesk</text>
  <text x="110" y="76" font-family="Inter" font-weight="300" font-size="16" letter-spacing="6.7" fill="#0BA5E0">OS</text>
</svg>
EOF
}
lockup "$tmp/lockup.svg"

# GRUB: a gradient background (stretched to the screen) and the logo on its own, so the logo
# keeps its proportions on every screen
cat > "$tmp/background.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="1024"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0E1A24"/><stop offset="1" stop-color="#082845"/></linearGradient></defs><rect width="64" height="1024" fill="url(#g)"/></svg>
EOF
rsvg-convert -o "$grub/live-theme/background.png" "$tmp/background.svg"
rsvg-convert --zoom 1.25 -o "$grub/live-theme/logo.png" "$tmp/lockup.svg"

# GRUB fonts (PF2) from Inter: menu entries and the footer
grub-mkfont -s 20 -o "$grub/live-theme/inter-regular-20.pf2" /usr/share/fonts/opentype/inter/Inter-Regular.otf
grub-mkfont -n "Inter SemiBold" -s 20 -o "$grub/live-theme/inter-semibold-20.pf2" /usr/share/fonts/opentype/inter/Inter-SemiBold.otf
grub-mkfont -s 14 -o "$grub/live-theme/inter-regular-14.pf2" /usr/share/fonts/opentype/inter/Inter-Regular.otf

# isolinux (BIOS): one 640x480 picture with the logo; the menu is drawn over its lower half
cat > "$tmp/isolinux.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="640" height="480">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0E1A24"/><stop offset="1" stop-color="#082845"/></linearGradient></defs>
  <rect width="640" height="480" fill="url(#g)"/>
  <image x="175" y="88" width="290" height="96" xlink:href="data:image/svg+xml;base64,$(base64 -w0 "$tmp/lockup.svg")"/>
</svg>
EOF
rsvg-convert -o "$isolinux/splash.png" "$tmp/isolinux.svg"


# GRUB: the highlight behind the selected entry (stretched; GRUB pixmap style "select_*.png")
cat > "$tmp/select.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#0BA5E0" fill-opacity="0.22"/></svg>
SVG
rsvg-convert -o "$grub/live-theme/select_c.png" "$tmp/select.svg"

ls -l "$grub/live-theme" "$isolinux/splash.png"
