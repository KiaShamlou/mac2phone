#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.polish/nearby-approval"
mkdir -p "$OUT/jvm" "$PWD/.polish/module-cache"
CP=$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.bouncycastle" -name '*.jar' -path '*1.86*' | sort | paste -sd: -)
[ -n "$CP" ] || { echo 'Build Android first to resolve Bouncy Castle.'; exit 1; }
swiftc -module-cache-path "$PWD/.polish/module-cache" Sources/mac2phone/{Pairing,Protocol,Server,Nearby}.swift Tests/Fixtures/NearbyFixture.swift -o "$OUT/nearby-fixture"
javac -cp "$CP" -d "$OUT/jvm" android/app/src/main/java/io/mac2phone/app/{Pairing,Wire,RemoteHost,ConnectionGrants,NearbyCrypto}.java android/app/src/test/java/io/mac2phone/app/NearbyFixture.java
node desktop/test/nearby-interop.cjs "$OUT/nearby-fixture" "$OUT/jvm:$CP"
