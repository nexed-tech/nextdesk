#!/usr/bin/env bash
#
# Renders the NextDesk boot splash images (Plymouth theme "nextdesk") from the SVG sources here
# into the package: os/package/root/usr/share/plymouth/themes/nextdesk/. The PNGs are committed,
# so building the package needs no renderer; run this after changing a source.
#
# Every change to the splash: bump the number in themes/nextdesk/version (0, 1, 2, ...). The
# package's postinst rebuilds the boot image when it changes, which is where Plymouth reads the
# theme from; without the bump, machines keep showing the old splash.
#
#   bash os/package/plymouth/render.sh      (Debian: apt install librsvg2-bin fonts-inter)
#
# Design: "1a, N on the desk" (NextDesk OS logo, Claude Design): the nexed.tech N standing on a
# desk bar, which is the boot progress bar; "NextDesk" / "OS" beside it. Sizes are the design's
# (mark 86x96, bar 100x9, gap 22) rendered at ZOOM; the script scales them to the screen.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/../root/usr/share/plymouth/themes/nextdesk"
ZOOM=2.5   # design px -> image px; the script draws them at (screen height / 1080) / 2
mkdir -p "$out"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

render() { rsvg-convert --zoom "$ZOOM" -o "$out/$1" "$2"; }

render mark.png "$here/../root/usr/share/nextdesk/nextdesk-mark.svg"

# The desk bar: a dim track, and the fill drawn over it as far as the boot has come
cat > "$tmp/track.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="9"><rect width="100" height="9" rx="4.5" fill="#FFFFFF" fill-opacity="0.14"/></svg>
EOF
cat > "$tmp/fill.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="9"><defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#046BC0"/><stop offset="1" stop-color="#0BA5E0"/></linearGradient></defs><rect width="100" height="9" rx="4.5" fill="url(#g)"/></svg>
EOF
render track.png "$tmp/track.svg"
render fill.png "$tmp/fill.svg"

# Wordmark: "NextDesk" (Inter Bold, white on the dark splash) over "OS" (Inter Light, wide)
cat > "$tmp/wordmark.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="160" height="56">
  <text x="0" y="30" font-family="Inter" font-weight="700" font-size="34" letter-spacing="-1.02" fill="#FFFFFF">NextDesk</text>
  <text x="1" y="52" font-family="Inter" font-weight="300" font-size="15" letter-spacing="6.3" fill="#0BA5E0">OS</text>
</svg>
EOF
render wordmark.png "$tmp/wordmark.svg"

# Disk password (encrypted installs): a line of text, a field, and a dot per typed character
cat > "$tmp/prompt.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="280" height="22">
  <text x="140" y="16" text-anchor="middle" font-family="Inter" font-weight="400" font-size="14" fill="#C9D6E2">Enter the disk password to start</text>
</svg>
EOF
cat > "$tmp/field.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="40"><rect x="0.5" y="0.5" width="239" height="39" rx="10" fill="#FFFFFF" fill-opacity="0.08" stroke="#0BA5E0" stroke-opacity="0.7"/></svg>
EOF
cat > "$tmp/dot.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><circle cx="4" cy="4" r="4" fill="#FFFFFF"/></svg>
EOF
render prompt.png "$tmp/prompt.svg"
render field.png "$tmp/field.svg"
render dot.png "$tmp/dot.svg"
ls -l "$out"
