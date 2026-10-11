#!/bin/sh
# Builds dist/LampBar.app: a release build wrapped in a menu bar app bundle, signed ad hoc.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product LampBar
app=dist/LampBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/LampBar" "$app/Contents/MacOS/LampBar"
iconset="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.lampbar.LampBar</string>
  <key>CFBundleName</key><string>Lamp Bar</string>
  <key>CFBundleDisplayName</key><string>Lamp Bar</string>
  <key>CFBundleExecutable</key><string>LampBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Lamp Bar switches the office lamps through the Kasa plugs and the Govee light bar on your local network.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
