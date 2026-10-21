#!/bin/bash
# Build an ad-hoc signed preview bundle only. No install, launch or permission changes.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$PWD/.polish/all-platforms/releases}"
mkdir -p "$OUT"
swift build -c release --disable-sandbox --scratch-path .polish/mac-release
APP="$OUT/Mac2Phone.app"
if [[ -e "$APP" ]]; then echo "Output already exists: $APP" >&2; exit 1; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .polish/mac-release/release/mac2phone "$APP/Contents/MacOS/"
cp Branding/Mac2Phone.icns Sources/mac2phone/Resources/WebIcon.png "$APP/Contents/Resources/"
python3 - "$APP" <<'PY'
import plistlib,sys
from pathlib import Path
info=dict(CFBundleExecutable='mac2phone',CFBundleIdentifier='com.kianoosh.mac2phone',CFBundleName='Mac2Phone',CFBundleDisplayName='Mac2Phone',CFBundleIconFile='Mac2Phone',CFBundlePackageType='APPL',CFBundleShortVersionString='0.4.0',CFBundleVersion='4',LSMinimumSystemVersion='14.0',LSUIElement=True,NSHighResolutionCapable=True,NSBonjourServices=['_m2p-nearby._tcp','_mac2phone._tcp'],NSLocalNetworkUsageDescription='Share this Mac with paired devices on your local network.',NSMicrophoneUsageDescription='Read the Mac2Phone virtual output device to share system sound. No microphone is intentionally recorded.')
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --identifier com.kianoosh.mac2phone --sign - "$APP"
codesign --verify --strict "$APP"
echo "MAC HOST PACKAGE: $APP (ad-hoc signed; not installed)"
