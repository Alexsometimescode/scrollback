#!/usr/bin/env zsh
# Build Scrollback.app (menu bar). No Xcode project, no dependencies: swiftc plus a folder.
set -euo pipefail

HERE="${0:A:h}"
APP="${HERE}/Scrollback.app"

rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"

VER=$(cat "${HERE}/../VERSION" 2>/dev/null || print 1.0.0)

swiftc -O "${HERE}/main.swift" "${HERE}/Collection.swift" "${HERE}/CalendarDates.swift" -o "${APP}/Contents/MacOS/Scrollback"

mkdir -p "${APP}/Contents/Resources"
cp "${HERE}/Scrollback.icns" "${APP}/Contents/Resources/" 2>/dev/null || true

# Bundle the scripts so the .app is self-contained and can live in /Applications
mkdir -p "${APP}/Contents/Resources/scripts"
cp "${HERE}"/../*.sh "${HERE}"/../schedule.conf "${APP}/Contents/Resources/scripts/" 2>/dev/null
chmod +x "${APP}/Contents/Resources/scripts/"*.sh
mkdir -p "${APP}/Contents/Resources/scripts/core"
cp "${HERE}"/../core/*.py "${APP}/Contents/Resources/scripts/core/"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Scrollback</string>
  <key>CFBundleDisplayName</key><string>Scrollback</string>
  <key>CFBundleIdentifier</key><string>com.beatbar.app</string>
  <key>CFBundleVersion</key><string>__VER__</string>
  <key>CFBundleShortVersionString</key><string>__VER__</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Scrollback</string>
  <key>CFBundleIconFile</key><string>Scrollback</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

/usr/bin/sed -i "" "s/__VER__/${VER}/g" "${APP}/Contents/Info.plist"

# Sign with a stable identity when the signing keychain is present, ad-hoc
# otherwise. This matters more than it looks: an ad-hoc signature's designated
# requirement IS the binary's own hash, so macOS treats every release as a
# different app and asks for every permission again. A certificate leaf keeps one
# identity across versions. Only the machine that BUILDS needs the keychain; the
# signature travels inside the zip.
KC="$HOME/Library/Keychains/beatbar-signing.keychain-db"
if [[ -f "$KC" && -r "$HOME/.beatbar/signing.pw" ]] \
   && security unlock-keychain -p "$(< "$HOME/.beatbar/signing.pw")" "$KC" 2>/dev/null \
   && codesign --force --sign "BeatBar Signing" "$APP" 2>/dev/null; then
  print -r -- "signed with the stable identity"
else
  codesign --force --sign - "$APP" 2>/dev/null || true
fi
print -r -- "built ${APP}"
