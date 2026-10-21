#!/bin/bash
# Requires a prior Android build. Synthetic only; no capture/input services.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .polish/all-platforms .polish/cross-platform .polish/module-cache
Scripts/check-android-interop.sh
swiftc -module-cache-path "$PWD/.polish/module-cache" Sources/mac2phone/{Protocol,Pairing,Server}.swift Tests/Fixtures/ServerFixture.swift -o .polish/cross-platform/server-fixture
CP=$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.bouncycastle" -name '*.jar' -path '*1.86*' | sort | paste -sd: -)
CP="$PWD/.polish/all-platforms/jvm:$CP"
FIX="$PWD/.polish/cross-platform/server-fixture"
KEY='QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE'
CHILD=''
trap '[[ -z "$CHILD" ]] || kill "$CHILD" 2>/dev/null || true' EXIT
"$FIX" 18771 > .polish/all-platforms/apple-jvm-host.log 2>&1 & CHILD=$!
for i in {1..60}; do grep -q READY .polish/all-platforms/apple-jvm-host.log && break; sleep .1; done
java -cp "$CP" io.mac2phone.app.InteropFixture client "mac2phone://127.0.0.1:18771#v2.00000000-0000-4000-8000-000000000001.$KEY"
kill "$CHILD"; wait "$CHILD" 2>/dev/null || true; CHILD=''
echo 'PASS Android JVM client ↔ Swift host: paired TLS, JPEG, PCM and Unicode input'
java -cp "$CP" io.mac2phone.app.InteropFixture host "mac2phone://127.0.0.1:18772#v2.00000000-0000-4000-8000-000000000001.$KEY" > .polish/all-platforms/jvm-apple-host.log 2>&1 & CHILD=$!
for i in {1..60}; do grep -q READY .polish/all-platforms/jvm-apple-host.log && break; sleep .1; done
"$FIX" --native-client 18772
echo 'PASS Apple Network native client ↔ Android JVM host: paired TLS and JPEG hello'
