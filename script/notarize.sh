#!/usr/bin/env bash
set -euo pipefail

# Build, Developer ID-sign, notarize, and staple BonsAI.app, then package a
# Gatekeeper-clean dist/BonsAI.app.zip (+ .sha256). Opens with a double-click
# on any Mac — no "damaged" / right-click dance.
#
# Local use (after `xcrun notarytool store-credentials "BonsAI-notary" …`):
#     ./script/notarize.sh
#
# CI use (env-driven notarization, no stored profile):
#     NOTARY_PROFILE= APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… ./script/notarize.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP="dist/BonsAI.app"
ZIP="dist/BonsAI.app.zip"
# Auto-detect the Developer ID Application identity from the keychain. Override with
# SIGN_IDENTITY="Developer ID Application: …" for forks or multiple identities.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
NOTARY_PROFILE="${NOTARY_PROFILE-BonsAI-notary}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no 'Developer ID Application' signing identity found in the keychain; set SIGN_IDENTITY=…" >&2
  exit 1
fi

echo "==> build & stage $APP"
./script/build_and_run.sh bundle

# build_and_run.sh stages SwiftPM's resource bundle at the .app root; move it to
# the canonical Contents/Resources so codesign seals it as a normal resource
# (Bundle.module checks Bundle.main.resourceURL first, so the app still finds it).
if [ -d "$APP/Composer_ComposerApp.bundle" ]; then
  mkdir -p "$APP/Contents/Resources"
  rm -rf "$APP/Contents/Resources/Composer_ComposerApp.bundle"
  mv "$APP/Composer_ComposerApp.bundle" "$APP/Contents/Resources/"
fi

echo "==> codesign with hardened runtime ($SIGN_IDENTITY)"
# Sparkle ships its helpers with its own signature (no secure timestamp, not our
# Developer ID), which Apple rejects. Re-sign every Sparkle component inside-out
# (nested helpers → framework), then the app. All get hardened runtime + a secure
# timestamp.
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$1"; }
SP="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SP" ]; then
  for comp in \
    "$SP/Versions/B/XPCServices/Downloader.xpc" \
    "$SP/Versions/B/XPCServices/Installer.xpc" \
    "$SP/Versions/B/Updater.app" \
    "$SP/Versions/B/Autoupdate"; do
    [ -e "$comp" ] && sign "$comp"
  done
  sign "$SP"
fi
sign "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> package & submit for notarization (this can take a few minutes)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
fi

echo "==> staple ticket & repackage"
xcrun stapler staple "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "==> verify Gatekeeper acceptance"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP" || true
echo "✓ notarized + stapled: $ZIP"
