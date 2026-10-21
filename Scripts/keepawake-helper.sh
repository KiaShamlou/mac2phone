#!/bin/bash
# Installed root-owned at /usr/local/libexec/mac2phone-keepawake.
#
# The flag file holds one word. Everything except lowercase letters is stripped
# before it is looked at, so nothing from the file can reach a shell.
#
# Nothing is written unless the setting actually differs from what the system
# already reports, so running this on a timer costs almost nothing.

FLAG="/Library/Application Support/Mac2Phone/keepawake"
LOG="/var/log/mac2phone-helper.log"

MODE="$(head -c 8 "$FLAG" 2>/dev/null | tr -cd 'a-z')"
case "$MODE" in
    full)  WANT_AWAKE=1; WANT_SAVER=0 ;;
    saver) WANT_AWAKE=1; WANT_SAVER=1 ;;
    *)     WANT_AWAKE=0; WANT_SAVER=0 ;;
esac

STATE="$(/usr/bin/pmset -g)"
HAVE_AWAKE="$(printf '%s\n' "$STATE" | awk '/SleepDisabled/{print $2; exit}')"
HAVE_SAVER="$(printf '%s\n' "$STATE" | awk '/lowpowermode/{print $2; exit}')"
[ -n "$HAVE_AWAKE" ] || HAVE_AWAKE=0
[ -n "$HAVE_SAVER" ] || HAVE_SAVER=0

if [ "$HAVE_AWAKE" != "$WANT_AWAKE" ]; then
    /usr/bin/pmset -a disablesleep "$WANT_AWAKE" \
        && echo "$(date '+%F %T') disablesleep -> $WANT_AWAKE (mode ${MODE:-none})" >> "$LOG" \
        || echo "$(date '+%F %T') disablesleep $WANT_AWAKE FAILED" >> "$LOG"
fi

if [ "$HAVE_SAVER" != "$WANT_SAVER" ]; then
    /usr/bin/pmset -a lowpowermode "$WANT_SAVER" 2>/dev/null \
        && echo "$(date '+%F %T') lowpowermode -> $WANT_SAVER" >> "$LOG"
fi
