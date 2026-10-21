#!/bin/bash
# Repeatable local/CI verification; never installs apps or changes permissions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for script in Scripts/*.sh; do bash -n "$script"; done
plutil -lint iOS/Info.plist iOS/Mac2Phone.xcodeproj/project.pbxproj >/dev/null
cmp Sources/mac2phone/Protocol.swift iOS/Mac2Phone/Protocol.swift
cmp Sources/mac2phone/Pairing.swift iOS/Mac2Phone/Pairing.swift
for file in desktop/*.cjs desktop/core/*.cjs desktop/renderer/*.js desktop/test/*.cjs; do node --check "$file"; done
node --test desktop/test/*.test.cjs
python3 Scripts/check-site.py --source
node --check site/src/modes.js
node --check site/src/usePageMotion.js
printf 'STATIC: shell syntax, plists, and protocol parity passed\n'
if [[ "${1:-}" == "--static" ]]; then exit 0; fi
swift test
xcodebuild -project iOS/Mac2Phone.xcodeproj -scheme Mac2Phone \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-check CODE_SIGNING_ALLOWED=NO build
