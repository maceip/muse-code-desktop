#!/usr/bin/env bash
# Helper to export your local "Developer ID Application" certificate (.p12) and
# optionally set the 5 GitHub Actions secrets required for automated macOS
# signing + Apple notarization in `.github/workflows/release.yml` and `ci.yml`.
#
# Usage:
#   scripts/prepare-apple-secrets.sh [--set-gh-secrets]

set -euo pipefail

SET_GH=0
if [[ "${1:-}" == "--set-gh-secrets" ]]; then
  SET_GH=1
fi

echo "==> Searching local Keychain for 'Developer ID Application' identities..."
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
  | head -n 1 || true)"

if [[ -z "${IDENTITY}" ]]; then
  cat >&2 <<'EOF'
ERROR: No "Developer ID Application" certificate was found in your local Keychain.

To create one:
  1. Sign in to https://developer.apple.com/account/resources/certificates/list
     (requires an Apple Developer Program membership).
  2. Click "+" -> select "Developer ID Application" (under Software) -> Continue.
  3. Open Keychain Access on your Mac -> Certificate Assistant ->
     "Request a Certificate From a Certificate Authority...", save the CSR to disk,
     upload it to developer.apple.com, and download the resulting `.cer` file.
  4. Double-click the downloaded `.cer` file to install it into your `login` keychain.
  5. Re-run `scripts/prepare-apple-secrets.sh`.
EOF
  exit 1
fi

TEAM_ID="$(echo "${IDENTITY}" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
echo "==> Found identity: ${IDENTITY}"
echo "==> Extracted Team ID: ${TEAM_ID}"

read -r -s -p "Enter a temporary export password for the .p12 bundle: " P12_PASSWORD
echo ""
if [[ -z "${P12_PASSWORD}" ]]; then
  echo "ERROR: Export password cannot be empty." >&2
  exit 1
fi

TMP_P12="$(mktemp /tmp/muse-devid.XXXXXX.p12)"
trap 'rm -f "${TMP_P12}"' EXIT

security export \
  -k "${HOME}/Library/Keychains/login.keychain-db" \
  -t identities \
  -f pkcs12 \
  -P "${P12_PASSWORD}" \
  -o "${TMP_P12}"

B64_CERT="$(base64 < "${TMP_P12}" | tr -d '\n')"

if [[ "${SET_GH}" -eq 1 ]]; then
  read -r -p "Enter your Apple ID email (APPLE_ID): " APPLE_ID_INPUT
  read -r -s -p "Enter your App-Specific Password (APPLE_APP_SPECIFIC_PASSWORD): " APPLE_PASS_INPUT
  echo ""

  echo "==> Setting GitHub Actions secrets via gh secret set..."
  printf '%s' "${B64_CERT}" | gh secret set MACOS_CERTIFICATE
  printf '%s' "${P12_PASSWORD}" | gh secret set MACOS_CERTIFICATE_PASSWORD
  printf '%s' "${APPLE_ID_INPUT}" | gh secret set APPLE_ID
  printf '%s' "${APPLE_PASS_INPUT}" | gh secret set APPLE_APP_SPECIFIC_PASSWORD
  printf '%s' "${TEAM_ID}" | gh secret set APPLE_TEAM_ID
  echo "==> All 5 GitHub Actions secrets configured!"
else
  cat <<EOF

==> Exported certificate! Set these 5 GitHub repository secrets (or re-run with --set-gh-secrets):

  APPLE_TEAM_ID=${TEAM_ID}
  MACOS_CERTIFICATE_PASSWORD=(the password you just entered)
  MACOS_CERTIFICATE=(base64 string below, ${#B64_CERT} chars)
  APPLE_ID=(your Apple Developer email)
  APPLE_APP_SPECIFIC_PASSWORD=(create at https://appleid.apple.com -> Sign-In and Security -> App-Specific Passwords)

--- BEGIN MACOS_CERTIFICATE (base64) ---
${B64_CERT}
--- END MACOS_CERTIFICATE (base64) ---
EOF
fi
