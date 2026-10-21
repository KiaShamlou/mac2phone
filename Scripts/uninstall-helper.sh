#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Run: sudo \"$0\""; exit 1; fi
LABEL="com.kianoosh.mac2phone.helper"
/usr/bin/pmset -a disablesleep 0 || true
/usr/bin/pmset -a lowpowermode 0 2>/dev/null || true
launchctl bootout system/$LABEL 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/libexec/mac2phone-keepawake
rm -f "/Library/Application Support/Mac2Phone/keepawake" /var/log/mac2phone-helper.log
echo "✔ removed, and lid-close sleep is back to normal"
