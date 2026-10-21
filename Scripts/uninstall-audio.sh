#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Run: sudo \"$0\""; exit 1; fi
rm -rf /Library/Audio/Plug-Ins/HAL/Mac2PhoneAudio.driver
killall coreaudiod 2>/dev/null || true
echo "✔ removed"
