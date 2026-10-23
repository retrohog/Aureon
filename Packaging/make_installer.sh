#!/bin/bash
# Builds the release app and wraps it in an installer disk image (and, with --pkg, an installer package).
#
#   ./Packaging/make_installer.sh [--pkg] [OUTPUT_FOLDER]
#
# The .dmg opens to Aureon.app next to an Applications shortcut: drag one onto the other. The .pkg installs into /Applications.
# ARCHS (see build_app.sh) selects the architectures; ARTIFACT_SUFFIX (for example -universal) is added to the file names.
# Output goes to OUTPUT_FOLDER (default: the repository folder). CODESIGN_IDENTITY / SKIP_SMARTDJ / SKIP_WHISPER work as in build_app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WITH_PKG=0; OUT="$ROOT"
for a in "$@"; do case "$a" in --pkg) WITH_PKG=1 ;; *) OUT="$a" ;; esac; done
mkdir -p "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/Packaging/build_app.sh" "$STAGE"
APP="$STAGE/Aureon.app"
[ -d "$APP" ] || { echo "error: the app was not built"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# disk image: the app, a shortcut to /Applications, and a short note about the first launch
DMGDIR="$STAGE/dmg"
mkdir -p "$DMGDIR"
cp -R "$APP" "$DMGDIR/Aureon.app"
ln -s /Applications "$DMGDIR/Applications"
cat > "$DMGDIR/READ ME FIRST.txt" <<TXT
Aureon $VERSION

1. Drag Aureon into Applications.
2. The first time, right-click (or Control-click) Aureon and choose Open, then confirm. macOS asks because the app is not
   notarised; after that it opens normally.
3. When macOS asks for access to your music folders, say Allow. The choice is remembered across updates.
TXT
SUFFIX="${ARTIFACT_SUFFIX:-}"
DMG="$OUT/Aureon-$VERSION$SUFFIX.dmg"
rm -f "$DMG"
hdiutil create -volname "Aureon $VERSION" -srcfolder "$DMGDIR" -format UDZO -fs HFS+ -ov "$DMG" >/dev/null
echo "Disk image: $DMG ($(du -h "$DMG" | cut -f1))"

if [ "$WITH_PKG" = 1 ]; then
  PKG="$OUT/Aureon-$VERSION$SUFFIX.pkg"
  rm -f "$PKG"
  pkgbuild --component "$APP" --install-location /Applications --identifier org.aureon.player.pkg --version "$VERSION" "$PKG" >/dev/null
  echo "Installer package: $PKG ($(du -h "$PKG" | cut -f1))"
fi
shasum -a 256 "$DMG" | sed "s#$OUT/##"
