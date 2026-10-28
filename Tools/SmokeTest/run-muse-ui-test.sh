#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/../.."

DERIVED="${TMPDIR:-/tmp}/pie-muse-ui-test"
mkdir -p "$DERIVED"

SOURCES=($(find PiCode -name '*.swift' ! -name 'PiCodeApp.swift'))

xcrun swiftc \
  -O \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  "${SOURCES[@]}" \
  Tools/SmokeTest/MuseUITestMain.swift \
  -o "$DERIVED/muse-ui-test"

"$DERIVED/muse-ui-test"
