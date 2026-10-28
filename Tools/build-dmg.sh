#!/usr/bin/env bash
# Build, sign, notarize, and package Muse Code (Pie.app) into a runnable
# macOS disk image (.dmg) and update archive (.zip).
#
# Usage:
#   Tools/build-dmg.sh [--debug|--release] [--no-notarize] [--allow-unsigned] [--identity "Developer ID Application: ..."]
#
# Environment variables (picked up automatically in CI and local release builds):
#   APP_VERSION                  Marketing version string (default: read from VERSION file)
#   BUILD_NUMBER                 CFBundleVersion (default: GITHUB_RUN_NUMBER or 1)
#   BUILD_CONFIG                 Xcode configuration: Debug (default) or Release
#   MUSE_CODESIGN_IDENTITY       Full name or SHA-1 of the "Developer ID Application: ..." certificate
#   MUSE_KEYCHAIN_PROFILE        Keychain profile created via `xcrun notarytool store-credentials`
#   APPLE_ID                     Apple ID email for notarytool (fallback when profile is not set)
#   APPLE_APP_SPECIFIC_PASSWORD  App-specific password for APPLE_ID
#   APPLE_TEAM_ID                10-character Apple Developer Team ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/MuseCode.xcodeproj"
ENTITLEMENTS="${REPO_ROOT}/MuseCode/MuseCode.entitlements"
BUILD_ROOT="${REPO_ROOT}/build"
DERIVED_DATA="${BUILD_ROOT}/DerivedData"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
DO_NOTARIZE=1
ALLOW_UNSIGNED=0
IDENTITY="${MUSE_CODESIGN_IDENTITY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      BUILD_CONFIG="Debug"
      shift
      ;;
    --release)
      BUILD_CONFIG="Release"
      shift
      ;;
    --no-notarize)
      DO_NOTARIZE=0
      shift
      ;;
    --allow-unsigned)
      ALLOW_UNSIGNED=1
      shift
      ;;
    --identity)
      IDENTITY="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${APP_VERSION:-}" ]]; then
  if [[ -f "${REPO_ROOT}/VERSION" ]]; then
    APP_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
  else
    APP_VERSION="1.5.1"
  fi
fi
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
CONFIG_LOWER="$(echo "${BUILD_CONFIG}" | tr '[:upper:]' '[:lower:]')"

echo "==> Muse Code macOS DMG packaging (v${APP_VERSION}, build ${BUILD_NUMBER}, config ${BUILD_CONFIG})"

# ---------------------------------------------------------------------------
# 1. Discover signing identity if not explicitly set
# ---------------------------------------------------------------------------
if [[ -z "${IDENTITY}" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1 || true)"
fi

if [[ -n "${IDENTITY}" ]]; then
  echo "==> Using Developer ID identity: ${IDENTITY}"
else
  echo "==> No 'Developer ID Application' certificate found in keychain; using ad-hoc Hardened Runtime signing (--sign -)"
  DO_NOTARIZE=0
fi

# Helper that runs `xcrun notarytool` with whichever credential set is configured.
run_notarytool() {
  if [[ -n "${MUSE_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool "$@" --keychain-profile "${MUSE_KEYCHAIN_PROFILE}"
  elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
    xcrun notarytool "$@" \
      --key "${APPLE_API_KEY_PATH}" \
      --key-id "${APPLE_API_KEY_ID}" \
      --issuer "${APPLE_API_ISSUER}"
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    xcrun notarytool "$@" \
      --apple-id "${APPLE_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}"
  else
    echo "ERROR: Notarization requested, but neither MUSE_KEYCHAIN_PROFILE, APPLE_API_KEY_*, nor APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD/APPLE_TEAM_ID are set." >&2
    return 1
  fi
}

has_notary_credentials() {
  [[ -n "${MUSE_KEYCHAIN_PROFILE:-}" ]] \
    || [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]] \
    || [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]
}

if [[ "${DO_NOTARIZE}" -eq 1 ]] && ! has_notary_credentials; then
  echo "==> No notarization credentials found in environment; skipping notarization step"
  DO_NOTARIZE=0
fi

# ---------------------------------------------------------------------------
# 2. Build Pie.app via xcodebuild (ENABLE_DEBUG_DYLIB=NO ensures a single
#    self-contained Mach-O executable in Debug builds on Xcode 16+)
# ---------------------------------------------------------------------------
mkdir -p "${BUILD_ROOT}"
echo "==> Building MuseCode (${BUILD_CONFIG}) via xcodebuild"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme MuseCode \
  -configuration "${BUILD_CONFIG}" \
  -derivedDataPath "${DERIVED_DATA}" \
  MARKETING_VERSION="${APP_VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

BUILT_APP="${DERIVED_DATA}/Build/Products/${BUILD_CONFIG}/Pie.app"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "ERROR: Expected built app bundle at ${BUILT_APP}" >&2
  exit 1
fi

STAGE_APP="${BUILD_ROOT}/Pie.app"
rm -rf "${STAGE_APP}"
ditto "${BUILT_APP}" "${STAGE_APP}"

# Remove any stray .debug.dylib if present from an incremental build
rm -f "${STAGE_APP}/Contents/MacOS/"*.debug.dylib

# Stamp version metadata in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${STAGE_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${STAGE_APP}/Contents/Info.plist"
plutil -lint "${STAGE_APP}/Contents/Info.plist"
plutil -lint "${ENTITLEMENTS}"

# ---------------------------------------------------------------------------
# 3. Code-sign Pie.app with Hardened Runtime + Entitlements
# ---------------------------------------------------------------------------
if [[ -n "${IDENTITY}" ]]; then
  echo "==> Signing Pie.app with Developer ID + Hardened Runtime"
  if [[ -d "${STAGE_APP}/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' item; do
      codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${item}"
    done < <(find "${STAGE_APP}/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -print0)
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${IDENTITY}" \
    "${STAGE_APP}"
else
  echo "==> Ad-hoc signing Pie.app with Hardened Runtime entitlements"
  codesign --force --deep --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign - \
    "${STAGE_APP}"
fi

echo "==> Verifying Pie.app signature"
codesign --verify --deep --strict --verbose=2 "${STAGE_APP}"

# ---------------------------------------------------------------------------
# 4. Notarize & staple Pie.app before packaging into DMG + ZIP
# ---------------------------------------------------------------------------
NOTARIZED_STATUS="not-notarized"
if [[ "${DO_NOTARIZE}" -eq 1 ]]; then
  APP_NOTARY_ZIP="${BUILD_ROOT}/Pie-notarize.zip"
  rm -f "${APP_NOTARY_ZIP}"
  echo "==> Creating archive ${APP_NOTARY_ZIP} for app notarization"
  ditto -c -k --keepParent "${STAGE_APP}" "${APP_NOTARY_ZIP}"

  echo "==> Submitting Pie.app to Apple notary service"
  run_notarytool submit "${APP_NOTARY_ZIP}" --wait
  rm -f "${APP_NOTARY_ZIP}"

  echo "==> Stapling notarization ticket to Pie.app"
  xcrun stapler staple "${STAGE_APP}"
  xcrun stapler validate "${STAGE_APP}"
  spctl --assess --type execute --verbose=4 "${STAGE_APP}"
  NOTARIZED_STATUS="notarized"
fi

# ---------------------------------------------------------------------------
# 5. Create MuseCode.zip (used by AppUpdater) and DMG
# ---------------------------------------------------------------------------
ZIP_OUT="${BUILD_ROOT}/MuseCode.zip"
VERSIONED_ZIP_OUT="${BUILD_ROOT}/muse-code-macos-${APP_VERSION}-${CONFIG_LOWER}.zip"
rm -f "${ZIP_OUT}" "${VERSIONED_ZIP_OUT}"
echo "==> Creating ${ZIP_OUT}"
ditto -c -k --sequesterRsrc --keepParent "${STAGE_APP}" "${ZIP_OUT}"
cp -f "${ZIP_OUT}" "${VERSIONED_ZIP_OUT}"

DMG_STAGE="${BUILD_ROOT}/dmg-root"
VERSIONED_DMG_OUT="${BUILD_ROOT}/muse-code-macos-${APP_VERSION}-${CONFIG_LOWER}.dmg"
DMG_OUT="${BUILD_ROOT}/MuseCode.dmg"
rm -rf "${DMG_STAGE}" "${VERSIONED_DMG_OUT}" "${DMG_OUT}"
mkdir -p "${DMG_STAGE}"
ditto "${STAGE_APP}" "${DMG_STAGE}/Pie.app"
ln -s /Applications "${DMG_STAGE}/Applications"

echo "==> Building compressed disk image ${VERSIONED_DMG_OUT}"
sync
DMG_CREATED=0
for attempt in 1 2 3 4 5; do
  rm -f "${VERSIONED_DMG_OUT}"
  if hdiutil create \
    -volname "Muse Code" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${VERSIONED_DMG_OUT}"; then
    DMG_CREATED=1
    break
  fi
  echo "WARN: hdiutil create attempt ${attempt}/5 failed (Spotlight/fseventsd lock); retrying in $((attempt * 2))s..." >&2
  sync
  sleep $((attempt * 2))
done
if [[ "${DMG_CREATED}" -ne 1 ]]; then
  echo "ERROR: Failed to create DMG after 5 attempts." >&2
  exit 1
fi
rm -rf "${DMG_STAGE}"

if [[ -n "${IDENTITY}" ]]; then
  echo "==> Signing DMG with Developer ID"
  codesign --force --timestamp --sign "${IDENTITY}" "${VERSIONED_DMG_OUT}"
else
  echo "==> Ad-hoc signing DMG"
  codesign --force --sign - "${VERSIONED_DMG_OUT}"
fi

if [[ "${DO_NOTARIZE}" -eq 1 ]]; then
  echo "==> Submitting DMG to Apple notary service"
  run_notarytool submit "${VERSIONED_DMG_OUT}" --wait

  echo "==> Stapling notarization ticket to DMG"
  xcrun stapler staple "${VERSIONED_DMG_OUT}"
  xcrun stapler validate "${VERSIONED_DMG_OUT}"
  spctl --assess --type open --context context:primary-signature --verbose=4 "${VERSIONED_DMG_OUT}"
fi

cp -f "${VERSIONED_DMG_OUT}" "${DMG_OUT}"
printf '%s\n' "${NOTARIZED_STATUS}" > "${BUILD_ROOT}/notarization.status"

# ---------------------------------------------------------------------------
# 6. Mount the built DMG and execute Pie.app --selftest directly from it
# ---------------------------------------------------------------------------
VERIFY_MOUNT="$(mktemp -d /tmp/muse-dmg-verify.XXXXXX)"
cleanup_mount() {
  hdiutil detach "${VERIFY_MOUNT}" -force >/dev/null 2>&1 || true
  rmdir "${VERIFY_MOUNT}" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT

echo "==> Mounting ${VERSIONED_DMG_OUT} to verify executable inside DMG"
hdiutil attach "${VERSIONED_DMG_OUT}" -mountpoint "${VERIFY_MOUNT}" -nobrowse -readonly -quiet
test -d "${VERIFY_MOUNT}/Pie.app"
test -L "${VERIFY_MOUNT}/Applications"
codesign --verify --deep --strict --verbose=2 "${VERIFY_MOUNT}/Pie.app"
"${VERIFY_MOUNT}/Pie.app/Contents/MacOS/Pie" --selftest
cleanup_mount
trap - EXIT

echo "==> Done:"
echo "    DMG (versioned): ${VERSIONED_DMG_OUT}"
echo "    DMG (canonical): ${DMG_OUT}"
echo "    ZIP (updater):   ${ZIP_OUT}"
echo "    Notarization:    ${NOTARIZED_STATUS}"
