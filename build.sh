#!/bin/zsh
# Builds Photo WiFi Receiver.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
swift build -c release --product SonyReceive
rm -rf "$ROOT/A7 Receive.app"
APP="$ROOT/Photo WiFi Receiver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/SonyReceive" "$APP/Contents/MacOS/SonyReceive"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                    <string>Photo WiFi Receiver</string>
    <key>CFBundleDisplayName</key>             <string>Photo WiFi Receiver</string>
    <key>CFBundleExecutable</key>              <string>SonyReceive</string>
    <key>CFBundleIdentifier</key>              <string>com.nng.a7receive</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>CFBundleShortVersionString</key>      <string>1.0</string>
    <key>CFBundleVersion</key>                 <string>1</string>
    <key>LSMinimumSystemVersion</key>          <string>13.0</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Photo WiFi Receiver looks for your camera on this Wi-Fi and downloads photos from it.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
