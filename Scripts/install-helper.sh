#!/bin/bash
# Lets Mac2Phone keep the Mac awake while its lid is shut.
#
# Closing the lid triggers an immediate sleep that ordinary power assertions
# cannot override — only `pmset disablesleep` can, and only root may set it.
# Rather than give the app root, this installs a tiny daemon that does exactly
# one thing: read a flag file and pass 0 or 1 to pmset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.kianoosh.mac2phone.helper"
HELPER="/usr/local/libexec/mac2phone-keepawake"
SUPPORT="/Library/Application Support/Mac2Phone"
FLAG="$SUPPORT/keepawake"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$(id -u)" -ne 0 ]; then
    echo "This one needs root. Run:"
    echo "  sudo \"$0\""
    exit 1
fi

OWNER="${SUDO_USER:-$(stat -f %Su /dev/console)}"

echo "▸ installing helper"
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel "$ROOT/Scripts/keepawake-helper.sh" "$HELPER"

# The directory stays root-owned; only the single flag file is writable by the
# user, so nothing else here can be swapped out.
mkdir -p "$SUPPORT"
chown root:wheel "$SUPPORT"
chmod 755 "$SUPPORT"
[ -f "$FLAG" ] || echo 0 > "$FLAG"
chown "$OWNER" "$FLAG"
chmod 644 "$FLAG"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$HELPER</string></array>
	<key>WatchPaths</key>
	<array><string>$FLAG</string></array>
	<!-- WatchPaths alone is not dependable, so a slow poll backs it up. The
	     script compares against what pmset already reports and does nothing
	     when they match, so this costs next to nothing. -->
	<key>StartInterval</key><integer>10</integer>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout system/$LABEL 2>/dev/null || true
sleep 1
launchctl bootstrap system "$PLIST"

echo
echo "✔ installed. Mac2Phone can now keep this Mac awake with the lid closed."
echo "  Turn it on from the menu bar, or from the phone under Settings ▸ Mac display."
echo
echo "  Log:    /var/log/mac2phone-helper.log"
echo "  Remove it later with: sudo Scripts/uninstall-helper.sh"
