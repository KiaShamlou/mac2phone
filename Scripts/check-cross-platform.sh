#!/bin/bash
# Synthetic loopback TLS integration; never runs the actual capture/input app.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .polish/cross-platform .polish/module-cache
node --test desktop/test/*.test.cjs
swiftc -module-cache-path "$PWD/.polish/module-cache" \
  Sources/mac2phone/Protocol.swift Sources/mac2phone/Pairing.swift \
  Sources/mac2phone/Server.swift Tests/Fixtures/ServerFixture.swift \
  -o .polish/cross-platform/server-fixture
node desktop/test/integration.cjs "$PWD/.polish/cross-platform/server-fixture"
