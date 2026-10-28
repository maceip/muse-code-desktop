#!/usr/bin/env bash
# Inspect a macOS .app bundle or .dmg image and verify its Developer ID
# signature, Hardened Runtime flag, notarization ticket staple, and Gatekeeper
# assessment.
#
# Usage:
#   scripts/check-notarization.sh <path-to-Pie.app-or-dmg> [--allow-adhoc]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-app-or-dmg> [--allow-adhoc]" >&2
  exit 1
fi

TARGET="$1"
ALLOW_ADHOC="${2:-}"

if [[ ! -e "${TARGET}" ]]; then
  echo "ERROR: ${TARGET} does not exist" >&2
  exit 1
fi

echo "==> Inspecting code signature on ${TARGET}"
SIG_INFO="$(codesign -dv --verbose=4 "${TARGET}" 2>&1)"
echo "${SIG_INFO}"

if echo "${SIG_INFO}" | grep -q "Signature=adhoc"; then
  if [[ "${ALLOW_ADHOC}" == "--allow-adhoc" ]]; then
    echo "WARN: ${TARGET} is ad-hoc signed (--allow-adhoc specified; skipping Gatekeeper/stapler checks)"
    exit 0
  fi
  echo "ERROR: ${TARGET} is ad-hoc signed, not signed with a Developer ID Application certificate." >&2
  exit 1
fi

if ! echo "${SIG_INFO}" | grep -q "Authority=Developer ID Application:"; then
  echo "ERROR: ${TARGET} is not signed with a 'Developer ID Application' certificate." >&2
  exit 1
fi

if [[ "${TARGET}" == *.app ]]; then
  echo "==> Verifying deep signature and Hardened Runtime on ${TARGET}"
  codesign --verify --deep --strict --verbose=2 "${TARGET}"
  if ! echo "${SIG_INFO}" | grep -q "flags=0x10000(runtime)"; then
    echo "ERROR: Hardened Runtime (flags=0x10000(runtime)) is not enabled on ${TARGET}." >&2
    exit 1
  fi
  echo "==> Validating stapled notarization ticket on ${TARGET}"
  xcrun stapler validate "${TARGET}"
  echo "==> Assessing Gatekeeper execution policy on ${TARGET}"
  spctl --assess --type execute --verbose=4 "${TARGET}"
elif [[ "${TARGET}" == *.dmg ]]; then
  echo "==> Validating stapled notarization ticket on ${TARGET}"
  xcrun stapler validate "${TARGET}"
  echo "==> Assessing Gatekeeper open policy on ${TARGET}"
  spctl --assess --type open --context context:primary-signature --verbose=4 "${TARGET}"
fi

echo "==> PASS: ${TARGET} is signed with Developer ID, notarized, stapled, and accepted by Gatekeeper."
