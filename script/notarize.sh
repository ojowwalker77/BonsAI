#!/usr/bin/env bash
set -euo pipefail

# Build, Developer ID-sign, notarize, and staple BonsAI.app, then package a
# Gatekeeper-clean dist/BonsAI.app.zip (+ .sha256). Opens with a double-click
# on any Mac — no "damaged" / right-click dance.
#
# Local use (after `xcrun notarytool store-credentials "BonsAI-notary" …`):
#     ./script/notarize.sh
#
# CI use (API-key notarization, no stored profile):
#     NOTARY_PROFILE= APPLE_API_KEY_PATH=… APPLE_API_KEY_ID=… APPLE_API_ISSUER_ID=… ./script/notarize.sh

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
# build_and_run.sh already stages the SwiftPM resource bundle in Contents/Resources (the codesign-clean
# location Bundle.appResources resolves), so there is nothing to relocate here before signing.

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
  : "${APPLE_API_KEY_PATH:?APPLE_API_KEY_PATH is required when NOTARY_PROFILE is empty}"
  : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required when NOTARY_PROFILE is empty}"
  : "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required when NOTARY_PROFILE is empty}"
  xcrun notarytool submit "$ZIP" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait
fi

echo "==> staple ticket & repackage"
xcrun stapler staple "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "==> verify Gatekeeper acceptance"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP"
echo "✓ notarized + stapled: $ZIP"

# Package the notarized, stapled app into a drag-to-install dmg too (the human download), then
# notarize + staple the dmg itself so it opens without a Gatekeeper prompt. The zip above stays the
# Sparkle appcast enclosure (the proven auto-update path); the dmg is purely for first-time installs.
echo "==> build drag-to-install dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-}" ./script/make_dmg.sh
