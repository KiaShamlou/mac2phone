#!/bin/bash
# Free Apple developer profiles expire after 7 days. Run this to rebuild and
# reinstall the iPhone app; the phone only needs to be plugged in or on Wi-Fi.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-}"

if [ -z "$DEVICE" ] || [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "Usage: DEVELOPMENT_TEAM=YOUR_TEAM_ID $0 <device-id>"
  echo "Find your device with: xcrun devicectl list devices"
  exit 1
fi

echo "▸ building for $DEVICE"
xcodebuild -project "$ROOT/iOS/Mac2Phone.xcodeproj" -scheme Mac2Phone -configuration Release \
  -destination "platform=iOS,id=$DEVICE" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates \
  -derivedDataPath "$ROOT/iOS/build" build >/dev/null

echo "▸ installing"
xcrun devicectl device install app --device "$DEVICE" \
  "$ROOT/iOS/build/Build/Products/Release-iphoneos/Mac2Phone.app"
echo "✔ done"
