#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .polish/all-platforms/jvm
CP=$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.bouncycastle" -name '*.jar' -path '*1.86*' | sort | paste -sd: -)
[ -n "$CP" ] || { echo 'Build Android first to resolve Bouncy Castle.'; exit 1; }
javac -cp "$CP" -d .polish/all-platforms/jvm android/app/src/main/java/io/mac2phone/app/{Pairing,Wire,RemoteHost,ConnectionGrants}.java android/app/src/test/java/io/mac2phone/app/InteropFixture.java
node desktop/test/android-interop.cjs "$PWD/.polish/all-platforms/jvm:$CP"
