#!/bin/bash
# Builds mac2phone, installs it as a background app, and starts it at every login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.kianoosh.mac2phone"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if [ -w /Applications ]; then APPS="/Applications"; else APPS="$HOME/Applications"; fi
APP="$APPS/Mac2Phone.app"

echo "▸ building…"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/mac2phone"

echo "▸ installing to $APP"
mkdir -p "$APPS"
# Keep the same bundle path so the granted privacy permissions survive updates.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/mac2phone"
cp -f "$ROOT/Branding/Mac2Phone.icns" "$APP/Contents/Resources/Mac2Phone.icns"
# macOS signed app bundles require resources inside Contents/Resources.
cp -f "$ROOT/Sources/mac2phone/Resources/WebIcon.png" "$APP/Contents/Resources/WebIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>mac2phone</string>
	<key>CFBundleIdentifier</key><string>$LABEL</string>
	<key>CFBundleName</key><string>Mac2Phone</string>
	<key>CFBundleDisplayName</key><string>Mac2Phone</string>
	<key>CFBundleIconFile</key><string>Mac2Phone</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Mac2Phone streams this Mac's screen to your iPhone over the local network.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Mac2Phone reads the Mac2Phone virtual output device so this Mac's sound can play on your iPhone. No microphone is recorded.</string>
</dict>
</plist>
PLIST

# Sign with a real identity when one exists. An ad-hoc signature pins the exact
# binary hash, so macOS revokes Screen Recording on every update; a certificate
# keeps the designated requirement stable and the permission sticks.
IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
           | grep -o '"Apple Develop[^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
  echo "▸ signing as $IDENTITY"
  codesign --force --options runtime --timestamp=none \
           --entitlements "$ROOT/Scripts/mac2phone.entitlements" \
           --identifier "$LABEL" --sign "$IDENTITY" "$APP"
else
  echo "▸ no developer certificate found, using ad-hoc signature"
  echo "  (Screen Recording will need re-approving after every update)"
  codesign --force --identifier "$LABEL" --sign - "$APP"
fi

echo "▸ registering login agent"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/mac2phone</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>$LOG_DIR/mac2phone.log</string>
	<key>StandardErrorPath</key><string>$LOG_DIR/mac2phone.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo
echo "✔ installed. It is running now and will start again at every login."
echo "  log:       $LOG_DIR/mac2phone.log"
echo "  hotkeys:   ctrl+opt+cmd+M  on/off      ctrl+opt+cmd+I  speak address"
echo
echo "One-time permissions — grant both to Mac2Phone, then run: $0"
echo "  System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording"
echo "  System Settings ▸ Privacy & Security ▸ Accessibility   (for touch/keyboard control)"
