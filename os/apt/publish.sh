#!/usr/bin/env bash
#
# Adds .deb files to the NextDesk apt repository and regenerates its signed indexes.
#
#   os/apt/publish.sh SITE_DIR DEB...
#
# SITE_DIR is a checkout of the gh-pages branch (served at https://repo.nexed.tech/).
# Packages go to pool/main/; a file that's already there is never replaced (apt caches packages
# by name and version, so changed content needs a new version). Signs with the key in
# APT_SIGNING_KEY (ASCII-armored private key) or the default gpg key.
#
# Layout: dists/trixie/{InRelease,Release,Release.gpg}, dists/trixie/main/binary-amd64/Packages*,
# pool/main/*.deb, nextdesk-archive-keyring.{gpg,asc}.

set -euo pipefail

SUITE=trixie
COMPONENT=main
ARCH=amd64

site="$1"; shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${APT_SIGNING_KEY:-}" ]; then
    export GNUPGHOME="$(mktemp -d)"
    trap 'rm -rf "$GNUPGHOME"' EXIT
    printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --quiet --import
fi

mkdir -p "$site/pool/$COMPONENT" "$site/dists/$SUITE/$COMPONENT/binary-$ARCH"
for deb in "$@"; do
    name="${deb##*/}"
    if [ -e "$site/pool/$COMPONENT/$name" ]; then
        if cmp -s "$deb" "$site/pool/$COMPONENT/$name"; then
            echo "unchanged: $name"
        else
            echo "::warning::$name is already published with different content; bump the version to publish it"
        fi
        continue
    fi
    cp "$deb" "$site/pool/$COMPONENT/"
    echo "added: $name"
done

cd "$site"
apt-ftparchive --arch "$ARCH" packages "pool/$COMPONENT" > "dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
gzip -9nkf "dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=NextDesk \
    -o APT::FTPArchive::Release::Label=NextDesk \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="$ARCH" \
    -o APT::FTPArchive::Release::Components="$COMPONENT" \
    -o APT::FTPArchive::Release::Description='NextDesk OS packages' \
    release "dists/$SUITE" > Release.tmp
mv Release.tmp "dists/$SUITE/Release"
gpg --batch --yes --armor --detach-sign -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
gpg --batch --yes --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"

# The public key, for the bootstrap to fetch before NextDesk's own package (which ships it) is in.
cp "$here/nextdesk-archive-keyring.asc" nextdesk-archive-keyring.asc
gpg --batch --yes --dearmor -o nextdesk-archive-keyring.gpg nextdesk-archive-keyring.asc
touch .nojekyll
cat > index.html <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>NextDesk apt repository</title></head>
<body><h1>NextDesk apt repository</h1>
<p>Debian 13 (trixie) packages for NextDesk OS. Install with the bootstrap script from
<a href="https://github.com/nexed-tech/nextdesk/tree/main/os">nexed-tech/nextdesk</a>.</p>
</body></html>
HTML
echo "Published $(grep -c '^Package:' "dists/$SUITE/$COMPONENT/binary-$ARCH/Packages") package version(s)."
