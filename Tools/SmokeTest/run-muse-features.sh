#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
APP="$PWD/MuseCode"
OUT="${TMPDIR:-/tmp}/picode-muse-features-test"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

mkdir -p "$OUT"
# shellcheck disable=SC2046
SOURCES=$(find "$APP/Models" "$APP/Services" "$APP/Shared" "$APP/Harness" -name '*.swift')

swiftc -Onone -g -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 \
  -parse-as-library \
  -o "$OUT/picode-muse-features" \
  Tools/SmokeTest/MuseFeaturesTest.swift $SOURCES

exec "$OUT/picode-muse-features"
