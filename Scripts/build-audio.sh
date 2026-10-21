#!/bin/bash
# Builds the virtual audio device bundle into Audio/build/Mac2PhoneAudio.driver
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Audio/Mac2PhoneAudio.c"
OUT="$ROOT/Audio/build/Mac2PhoneAudio.driver"
FACTORY_UUID="9A1C7E52-4B6D-4F0A-8E3B-2D5C71A9F6E4"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

clang -std=c11 -O2 -Wall -arch arm64 -arch x86_64 \
      -bundle -framework CoreFoundation -framework CoreAudio \
      -o "$OUT/Contents/MacOS/Mac2PhoneAudio" "$SRC"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Mac2PhoneAudio</string>
	<key>CFBundleIdentifier</key><string>com.kianoosh.mac2phone.audio</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Mac2PhoneAudio</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFPlugInFactories</key>
	<dict>
		<key>$FACTORY_UUID</key>
		<string>Mac2PhoneAudio_Create</string>
	</dict>
	<key>CFPlugInTypes</key>
	<dict>
		<key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
		<array><string>$FACTORY_UUID</string></array>
	</dict>
	<key>NSHumanReadableCopyright</key><string>Mac2Phone</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | grep -o '"Apple Develop[^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$OUT"
else
  codesign --force --sign - "$OUT"
fi
codesign --verify --verbose=1 "$OUT" 2>&1 | tail -1
echo "✔ built $OUT"
