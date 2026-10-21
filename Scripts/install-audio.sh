#!/bin/bash
# Installs the Mac2Phone virtual output device. Needs root: HAL plug-ins live in
# a system directory and coreaudiod has to be restarted to pick them up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/Audio/build/Mac2PhoneAudio.driver"
DEST="/Library/Audio/Plug-Ins/HAL"

if [ "$(id -u)" -ne 0 ]; then
  echo "This one needs root. Run:"
  echo "  sudo \"$0\""
  exit 1
fi

[ -d "$DRIVER" ] || { echo "Build it first: Scripts/build-audio.sh"; exit 1; }

echo "▸ installing to $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/Mac2PhoneAudio.driver"
cp -R "$DRIVER" "$DEST/"
chown -R root:wheel "$DEST/Mac2PhoneAudio.driver"

echo "▸ restarting coreaudiod (all audio cuts out for a second)"
killall coreaudiod 2>/dev/null || true
sleep 3

if system_profiler SPAudioDataType 2>/dev/null | grep -q "Mac2Phone"; then
  echo "✔ done — 'Mac2Phone' now appears in Sound ▸ Output"
else
  echo "⚠ the device did not appear. Check: log show --last 2m --predicate 'process == \"coreaudiod\"' | grep -i mac2phone"
fi
