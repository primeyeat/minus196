#!/bin/bash
# Builds the SwiftUI app and wraps it as build/-196.app (ad-hoc signed: other Macs warn before opening it).
# Also makes build/minus196.dmg, the disk image attached to releases.
# Usage: ./make-app.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
swift build -c release --product Minus196App
APP="$HERE/build/-196.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Minus196App" "$APP/Contents/MacOS/minus196"
mkdir -p "$APP/Contents/Resources"
cp "$HERE/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # made by icon/make-icon.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>-196</string>
    <key>CFBundleDisplayName</key><string>-196</string>
    <key>CFBundleIdentifier</key><string>local.minus196.app</string>
    <key>CFBundleExecutable</key><string>minus196</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "built $APP"
# A disk image for a release: the app beside a shortcut to the Applications folder.
DMG="$HERE/build/minus196.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG" "$HERE/build/minus196-app.zip"
hdiutil create -quiet -volname "-196" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
rm -rf "$STAGE"
echo "disk image: $DMG"
