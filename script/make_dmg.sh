#!/usr/bin/env bash
set -euo pipefail

# Build a drag-to-install dist/BonsAI.dmg from the already-built dist/BonsAI.app: a window with the
# app on the left and an /Applications shortcut on the right, so users drag BonsAI onto Applications
# to install (which also moves it out of Downloads, sidestepping App Translocation). When signing
# credentials are present the .dmg is notarized + stapled so it opens with a plain double-click.
#
# Run after script/notarize.sh (or after a local build_and_run.sh bundle for an explicitly local .dmg):
#     ./script/make_dmg.sh
#     DMG_NOTARIZE=false ./script/make_dmg.sh   # local-only unsigned package
#
# CI use mirrors notarize.sh's API-key or Apple ID/app-password path.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP="dist/BonsAI.app"
VOLNAME="BonsAI"
DMG="dist/BonsAI.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE-BonsAI-notary}"
DMG_NOTARIZE="${DMG_NOTARIZE:-true}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — build it first (./script/build_and_run.sh bundle or notarize.sh)" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"
# Same auto-detection as notarize.sh; override with SIGN_IDENTITY=… for forks/multiple identities.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"

echo "==> assemble dmg staging ($VERSION)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto preserves the signature/symlinks/xattrs; plain cp -R can mangle a signed bundle.
ditto "$APP" "$STAGE/BonsAI.app"
ln -s /Applications "$STAGE/Applications"

echo "==> build $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov "$DMG" >/dev/null

# Decide whether to notarize. Release callers must provide credentials; only an explicit
# DMG_NOTARIZE=false creates a local unsigned package.
have_creds=false
if [ -n "${NOTARY_PROFILE:-}" ]; then
  have_creds=true
elif [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
  have_creds=true
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  have_creds=true
fi

if [ "$DMG_NOTARIZE" = "true" ]; then
  if [ "$have_creds" != "true" ]; then
    echo "error: notarization credentials are required; set DMG_NOTARIZE=false only for a local package." >&2
    exit 1
  fi
  # Code-sign the .dmg with Developer ID BEFORE notarizing. A notarized-but-unsigned dmg still fails
  # `spctl --assess -t open` ("no usable signature") and can prompt on download; signing first makes
  # Gatekeeper accept it as "Notarized Developer ID". (codesign changes the dmg's hash, so this must
  # precede notarization + stapling.)
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "error: a Developer ID Application identity is required to sign the DMG." >&2
    exit 1
  fi
  echo "==> codesign $DMG ($SIGN_IDENTITY)"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  echo "==> notarize + staple $DMG (this can take a few minutes)"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
    xcrun notarytool submit "$DMG" \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER_ID" \
      --wait
  else
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "✓ notarized + stapled: $DMG"
else
  echo "note: $DMG is an unsigned local-only package (DMG_NOTARIZE=false)." >&2
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ packaged $DMG"
