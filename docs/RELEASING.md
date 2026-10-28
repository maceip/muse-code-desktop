# Releasing & Notarizing Muse Code for macOS

This document covers building, signing, notarizing, and verifying the macOS `.dmg` and `.zip` artifacts locally and in GitHub Actions CI.

---

## 1. Local Build, Sign, Notarize & Self-Test

### One-Time Keychain Setup (Local Machine)

1. Install your **Developer ID Application** certificate in Keychain Access (`Developer ID Application: Your Name (TEAMID)`).
2. Store an App Store Connect / Notary credentials profile in your login keychain:
   ```bash
   xcrun notarytool store-credentials "muse-notary" \
     --apple-id "you@example.com" \
     --team-id "YOURTEAM10" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

### Build & Notarize a Debug DMG

```bash
export MUSE_KEYCHAIN_PROFILE="muse-notary"
Tools/build-dmg.sh --debug
```

`Tools/build-dmg.sh` performs the full pipeline:
1. Builds `Pie.app` via `xcodebuild` (`-scheme MuseCode -configuration Debug`, `ENABLE_DEBUG_DYLIB=NO` so Xcode 16+ produces a single standalone Mach-O binary).
2. Stamps `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
3. Signs `Pie.app` with `--options runtime --timestamp --entitlements MuseCode/MuseCode.entitlements`.
4. Submits `Pie.app` to `xcrun notarytool submit --wait` and staples the ticket via `xcrun stapler staple`.
5. Packages `Pie.app` and `/Applications` symlink into `build/muse-code-macos-<version>-debug.dmg` (`build/MuseCode.dmg`) and `build/MuseCode.zip`.
6. Signs, notarizes, and staples the `.dmg`.
7. Mounts the resulting `.dmg` read-only and executes `Pie.app/Contents/MacOS/Pie --selftest` directly from the mounted volume to verify the packaged app launches and passes all bundle/asset/service checks.

### Verify Notarization & Gatekeeper

```bash
scripts/check-notarization.sh build/MuseCode.dmg
```

---

## 2. GitHub Actions CI & Automated Releases

- **`.github/workflows/ci.yml`**: Runs on every push and pull request to `main`. Builds the Debug `.app` and `.dmg`, signs and notarizes when Apple secrets are present (or falls back to ad-hoc Hardened Runtime signing when secrets are not yet configured), mounts the `.dmg`, runs `Pie.app/Contents/MacOS/Pie --selftest`, and uploads the runnable Debug `.dmg` and `.zip` as workflow artifacts (`muse-code-macos-debug-dmg`).
- **`.github/workflows/release.yml`**: Runs on pushes to `main`, `v*` tags, and manual `workflow_dispatch`. Builds, signs, notarizes (when secrets are configured), verifies the mounted Debug `.dmg` via `--selftest`, uploads workflow artifacts, and publishes a GitHub Release (`v<VERSION>-dev.<RUN_NUMBER>` on `main` or `<tag>` on tag pushes) with the downloadable `.dmg` and `.zip`.

### Configuring Repository Secrets for Cloud Notarization

Run:

```bash
scripts/prepare-apple-secrets.sh --set-gh-secrets
```

Or configure the 5 repository secrets manually in **Settings -> Secrets and variables -> Actions**:
- `MACOS_CERTIFICATE` — Base64-encoded `.p12` containing your `Developer ID Application` certificate and private key.
- `MACOS_CERTIFICATE_PASSWORD` — Password used when exporting the `.p12`.
- `APPLE_ID` — Apple ID email associated with your Apple Developer account.
- `APPLE_APP_SPECIFIC_PASSWORD` — App-specific password generated at [appleid.apple.com](https://appleid.apple.com).
- `APPLE_TEAM_ID` — 10-character Apple Developer Team ID.
