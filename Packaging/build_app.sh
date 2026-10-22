#!/bin/bash
# Builds "Aureon.app" and installs it into the given folder (default: ~/Desktop).
#
#   ./Packaging/build_app.sh [--with-helper] [DEST_FOLDER]
#
# The Smart DJ language model is a separate program (Packages/SmartDJHelper, built with MLX). It is built with xcodebuild and embedded
# when full Xcode with the Metal toolchain is installed; otherwise the app is built without it and Smart DJ falls back to plain ranking.
#   SKIP_SMARTDJ=1  never build it       REBUILD_SMARTDJ=1  rebuild even if a build exists
#
# --with-helper embeds the privileged quiet-mode helper (Contents/MacOS/AureonHelper) and its launchd plist
#               (Contents/Library/LaunchDaemons/org.aureon.helper.plist) for SMAppService. macOS only lets a *signed* app register it:
#               set CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)". Without it the bundle is ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
WITH_HELPER=0; DEST="$HOME/Desktop"
for a in "$@"; do case "$a" in --with-helper) WITH_HELPER=1 ;; *) DEST="$a" ;; esac; done
APP="$DEST/Aureon.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"

W="$(mktemp -d)"
swift Packaging/make_icon.swift "$W/icon.png"
mkdir "$W/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$W/icon.png" --out "$W/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$W/icon.png" --out "$W/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$W/AppIcon.iconset" -o "$W/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/Aureon" "$APP/Contents/MacOS/Aureon"
cp "$W/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Aureon</string>
  <key>CFBundleDisplayName</key><string>Aureon</string>
  <key>CFBundleIdentifier</key><string>org.aureon.player</string>
  <key>CFBundleExecutable</key><string>Aureon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSMicrophoneUsageDescription</key><string>Some Audio Unit plugins request audio input access.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Aureon lets your phone or tablet control playback and browse your library over the local network, finds other Aureon servers, and finds Chromecast and Google Home speakers to cast to.</string>
  <key>NSBonjourServices</key><array><string>_aureon._tcp</string><string>_googlecast._tcp</string></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Audio</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.audio</string></array>
  </dict></array>
</dict></plist>
PLIST

if [ "$WITH_HELPER" = 1 ]; then
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp "$BINDIR/AureonHelper" "$APP/Contents/MacOS/AureonHelper"
  cat > "$APP/Contents/Library/LaunchDaemons/org.aureon.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.aureon.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/AureonHelper</string>
  <key>MachServices</key><dict><key>org.aureon.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>org.aureon.player</string></array>
</dict></plist>
PLIST
  codesign --force --options runtime -s "$IDENTITY" "$APP/Contents/MacOS/AureonHelper" 2>&1 | tail -1
fi

# Smart DJ language model helper
SMART_SRC="Packages/SmartDJHelper"
SMART_OUT="$SMART_SRC/.build/xcode/Build/Products/Release"
if [ "${SKIP_SMARTDJ:-0}" != 1 ]; then
  if [ ! -x "$SMART_OUT/AureonSmartDJ" ] || [ "${REBUILD_SMARTDJ:-0}" = 1 ]; then
    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --find metal >/dev/null 2>&1; then
      echo "Building the Smart DJ language model helper (first time: a few minutes)…"
      ( cd "$SMART_SRC" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme AureonSmartDJ -configuration Release -destination 'platform=macOS' \
          -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation build >/tmp/aureon-smartdj-build.log 2>&1 ) \
        || echo "note: the Smart DJ helper did not build (see /tmp/aureon-smartdj-build.log); the app will use plain ranking."
    else
      echo "note: Xcode with the Metal toolchain was not found, so the Smart DJ language model is not included (xcodebuild -downloadComponent MetalToolchain)."
    fi
  fi
  if [ -x "$SMART_OUT/AureonSmartDJ" ]; then
    H="$APP/Contents/Helpers/AureonSmartDJ"
    mkdir -p "$H"
    cp "$SMART_OUT/AureonSmartDJ" "$H/"
    for b in "$SMART_OUT"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$H/"; done
    echo "Smart DJ language model helper included ($(du -sh "$H" | cut -f1))"
  fi
fi

codesign --force --deep -s "$IDENTITY" "$APP" 2>&1 | tail -1
echo "Installed: $APP$([ "$WITH_HELPER" = 1 ] && echo ' (with helper)')"
if [ "$WITH_HELPER" = 1 ] && [ "$IDENTITY" = "-" ]; then echo "note: ad-hoc signed; macOS will not let you register the helper (set CODESIGN_IDENTITY)."; fi
