#!/bin/zsh
# Builds "Network Fixer.app" and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Network Fixer.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/NetworkFixer" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Network Fixer</string>
  <key>CFBundleDisplayName</key><string>Network Fixer</string>
  <key>CFBundleIdentifier</key><string>local.tannersmitheram.NetworkFixer</string>
  <key>CFBundleExecutable</key><string>NetworkFixer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>Network Fixer uses Location access only to read your Wi-Fi network name (SSID), which macOS treats as location data.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Network Fixer uses Location access only to read your Wi-Fi network name (SSID), which macOS treats as location data.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NetworkFixer 2>/dev/null || true
  rm -rf "/Applications/Network Fixer.app"
  cp -R "$APP" /Applications/
  open "/Applications/Network Fixer.app"
  echo "Installed to /Applications and launched"
fi
