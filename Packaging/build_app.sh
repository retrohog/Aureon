#!/bin/bash
# Builds "Aureon.app" and installs it into the given folder (default: ~/Desktop).
#
#   ./Packaging/build_app.sh [--with-helper] [DEST_FOLDER]
#
# The Smart DJ language model is a separate program (Packages/SmartDJHelper, built with MLX). It is built with xcodebuild and embedded
# when full Xcode with the Metal toolchain is installed; otherwise the app is built without it and Smart DJ falls back to plain ranking.
#   SKIP_SMARTDJ=1  never build it       REBUILD_SMARTDJ=1  rebuild even if a build exists
#
# The lyrics speech model (Whisper) is another separate program (Packages/WhisperHelper, WhisperKit), built and embedded the same way.
#   SKIP_WHISPER=1  never build it       REBUILD_WHISPER=1  rebuild even if a build exists
#
# ARCHS="arm64 x86_64" (default) builds a universal app: each slice is built on its own and joined with lipo. ARCHS=arm64 (or x86_64)
#               gives a single-architecture build, which is faster for development. The Smart DJ helper is always arm64-only (MLX runs only on
#               Apple Silicon); the lyrics helper is arm64 unless WHISPER_ARCHS="arm64 x86_64" is set and WhisperKit builds for it.
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

ARCHS="${ARCHS:-arm64 x86_64}"
MINOS=15.0
# Each slice gets its own scratch folder: the products folder does not depend on --triple, so one shared folder would be overwritten.
build_slice() { swift build -c release --triple "$1-apple-macosx$MINOS" --scratch-path ".build/slice-$1" "${@:2}"; }
for a in $ARCHS; do
  case "$a" in arm64|x86_64) ;; *) echo "error: unsupported architecture '$a' (use arm64 and/or x86_64)"; exit 1 ;; esac
  build_slice "$a"
done

# Copies the one slice, or joins all slices into one universal binary: join_slices <product> <destination>
join_slices() {
  local ins=() a
  for a in $ARCHS; do ins+=("$(build_slice "$a" --show-bin-path)/$1"); done
  if [ "${#ins[@]}" = 1 ]; then cp "${ins[0]}" "$2"; else lipo -create "${ins[@]}" -output "$2"; fi
}
# Fails the build when a slice is missing from a binary: check_slices <binary>
check_slices() {
  local have a; have=" $(lipo -archs "$1") "
  for a in $ARCHS; do case "$have" in *" $a "*) ;; *) echo "error: $1 has no $a slice (has:$have)"; exit 1 ;; esac; done
}

W="$(mktemp -d)"
swift Packaging/make_icon.swift "$W/icon.png" Packaging/AppIcon-source.png
mkdir "$W/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$W/icon.png" --out "$W/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$W/icon.png" --out "$W/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$W/AppIcon.iconset" -o "$W/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
join_slices Aureon "$APP/Contents/MacOS/Aureon"
check_slices "$APP/Contents/MacOS/Aureon"
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
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSMicrophoneUsageDescription</key><string>Some Audio Unit plugins request audio input access.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Aureon lets your phone or tablet control playback and browse your library over the local network, finds other Aureon servers, finds Chromecast, Sonos and DLNA speakers to play to, and syncs your library to the companion app.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Aureon reads and plays music that you keep in your Desktop folder.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Aureon reads and plays music that you keep in your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Aureon reads and plays music that you keep in your Downloads folder.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Aureon plays music from your external drives and USB DACs.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Aureon plays music from your network shares and NAS.</string>
  <key>NSBonjourServices</key><array><string>_aureon._tcp</string><string>_googlecast._tcp</string><string>_aureonsync._tcp</string><string>_aureonpair._tcp</string></array>
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
  join_slices AureonHelper "$APP/Contents/MacOS/AureonHelper"
  check_slices "$APP/Contents/MacOS/AureonHelper"
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
      ( cd "$SMART_SRC" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme AureonSmartDJ -configuration Release -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
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

# Lyrics generation: the on-device speech model (Whisper via WhisperKit/CoreML), a separate program like the Smart DJ model.
#   SKIP_WHISPER=1  never build it       REBUILD_WHISPER=1  rebuild even if a build exists
WHISPER_SRC="Packages/WhisperHelper"
WHISPER_OUT="$WHISPER_SRC/.build/xcode/Build/Products/Release"
if [ "${SKIP_WHISPER:-0}" != 1 ]; then
  if [ ! -x "$WHISPER_OUT/AureonWhisper" ] || [ "${REBUILD_WHISPER:-0}" = 1 ]; then
    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --find xcodebuild >/dev/null 2>&1; then
      echo "Building the lyrics speech-model helper (first time: a few minutes)…"
      ( cd "$WHISPER_SRC" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme AureonWhisper -configuration Release -destination 'platform=macOS' ARCHS="${WHISPER_ARCHS:-arm64}" ONLY_ACTIVE_ARCH=NO \
          -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation build >/tmp/aureon-whisper-build.log 2>&1 ) \
        || echo "note: the lyrics helper did not build (see /tmp/aureon-whisper-build.log); lyrics from files and the internet still work."
    else
      echo "note: Xcode was not found, so generating lyrics with a speech model is not included."
    fi
  fi
  if [ -x "$WHISPER_OUT/AureonWhisper" ]; then
    H="$APP/Contents/Helpers/AureonWhisper"
    mkdir -p "$H"
    cp "$WHISPER_OUT/AureonWhisper" "$H/"
    for b in "$WHISPER_OUT"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$H/"; done
    echo "Lyrics speech-model helper included ($(du -sh "$H" | cut -f1))"
  fi
fi

# Resource bundles inside the helpers are sealed first: codesign refuses to seal the app around nested code that is not signed.
# A universal helper comes out of xcodebuild without a signature (a single-architecture one is signed by the linker), so sign each program too.
for x in "$APP"/Contents/Helpers/*/Aureon*; do [ -f "$x" ] && [ -x "$x" ] && codesign --force -s "$IDENTITY" "$x" >/dev/null 2>&1; done
for b in "$APP"/Contents/Helpers/*/*.bundle; do [ -e "$b" ] && codesign --force -s "$IDENTITY" "$b" >/dev/null 2>&1; done

if [ "$IDENTITY" = "-" ]; then
  # An ad-hoc signature is identified by the hash of the binary, which changes with every build, so macOS forgets the folder and volume
  # access you granted and asks again. Pinning the designated requirement to the bundle identifier keeps those grants across rebuilds.
  codesign --force -s - -r='designated => identifier "org.aureon.player"' "$APP" 2>&1 | tail -1
else
  codesign --force --deep -s "$IDENTITY" "$APP" 2>&1 | tail -1
fi
codesign --verify --strict "$APP" || { echo "error: the signature of $APP does not verify"; exit 1; }
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Aureon")"
echo "Installed: $APP$([ "$WITH_HELPER" = 1 ] && echo ' (with helper)')"
if [ "$WITH_HELPER" = 1 ] && [ "$IDENTITY" = "-" ]; then echo "note: ad-hoc signed; macOS will not let you register the helper (set CODESIGN_IDENTITY)."; fi
