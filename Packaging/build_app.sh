#!/bin/bash
# Builds "Aureon.app" and installs it into the given folder (default: ~/Desktop).
#
#   ./Packaging/build_app.sh [--with-helper] [DEST_FOLDER]
#
# ARCHS="arm64 x86_64" (default) builds a universal app: each slice is built on its own and joined with lipo. ARCHS=arm64 (or x86_64)
#               gives a single-architecture build, which is faster for development. The app runs on macOS 13 or later (MINOS below).
#
# --with-helper embeds the privileged quiet-mode helper (Contents/MacOS/AureonHelper) and its launchd plist
#               (Contents/Library/LaunchDaemons/org.aureon.helper.plist) for SMAppService. macOS only lets a *signed* app register it:
#               set CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)". Without it the bundle is ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
WITH_HELPER=0; DEST="$HOME/Desktop"
for a in "$@"; do case "$a" in --with-helper) WITH_HELPER=1 ;; *) DEST="$a" ;; esac; done
APP="$DEST/Aureon.app"
# The release number lives in Packaging/VERSION (one line, for example 0.4.0); the build number is derived from it (0.4.0 becomes 400).
VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
BUILD="$(echo "$VERSION" | awk -F. '{ print $1 * 10000 + $2 * 100 + $3 }')"
IDENTITY="${CODESIGN_IDENTITY:--}"

ARCHS="${ARCHS:-arm64 x86_64}"
MINOS=13.0
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
# the interface font and its licence, when they are in Packaging/Fonts
if [ -d Packaging/Fonts ]; then mkdir -p "$APP/Contents/Resources/Fonts" && cp Packaging/Fonts/* "$APP/Contents/Resources/Fonts/"; fi
# fonts that are only on this machine (not in the repository; see .gitignore), for example Chillax: bundled only when the folder is there
if [ -d Packaging/Fonts-local ] && ls Packaging/Fonts-local/*.otf Packaging/Fonts-local/*.ttf >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources/Fonts" && cp Packaging/Fonts-local/* "$APP/Contents/Resources/Fonts/"
  echo "Local fonts bundled: $(ls Packaging/Fonts-local | tr '\n' ' ')"
fi
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
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__BUILD__</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSMicrophoneUsageDescription</key><string>Aureon uses the microphone for the DJ console's mic channel, and some Audio Unit plugins also ask for audio input.</string>
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
sed -i '' -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$APP/Contents/Info.plist"

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
