#!/bin/bash
set -euo pipefail
LABEL="com.kianoosh.mac2phone"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf /Applications/Mac2Phone.app "$HOME/Applications/Mac2Phone.app"
echo "✔ removed. Also clear Mac2Phone from Privacy & Security if you like."
