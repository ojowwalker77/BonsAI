#!/usr/bin/env bash
set -euo pipefail

# Build a drag-to-install dist/BonsAI.dmg from the already-built dist/BonsAI.app: a window with the
# app on the left and an /Applications shortcut on the right, so users drag BonsAI onto Applications
# to install (which also moves it out of Downloads, sidestepping App Translocation). When signing
# credentials are present the .dmg is notarized + stapled so it opens with a plain double-click.
#
# Run after script/notarize.sh (or after a local build_and_run.sh bundle for an unsigned .dmg):
#     ./script/make_dmg.sh                 # notarize if creds available, else plain .dmg
#     DMG_NOTARIZE=false ./script/make_dmg.sh   # never notarize (CI unsigned fallback)
#
# CI use mirrors notarize.sh's env-driven path:
#     NOTARY_PROFILE= APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… ./script/make_dmg.sh

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

# Decide whether to notarize: explicit opt-out, or no usable credentials.
have_creds=false
if [ -n "${NOTARY_PROFILE:-}" ]; then
  have_creds=true
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  have_creds=true
fi

if [ "$DMG_NOTARIZE" = "true" ] && [ "$have_creds" = "true" ]; then
  # Code-sign the .dmg with Developer ID BEFORE notarizing. A notarized-but-unsigned dmg still fails
  # `spctl --assess -t open` ("no usable signature") and can prompt on download; signing first makes
  # Gatekeeper accept it as "Notarized Developer ID". (codesign changes the dmg's hash, so this must
  # precede notarization + stapling.)
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> codesign $DMG ($SIGN_IDENTITY)"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  else
    echo "::warning::no Developer ID identity found — notarizing an unsigned dmg (may still prompt on open)." >&2
  fi
  echo "==> notarize + staple $DMG (this can take a few minutes)"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "✓ notarized + stapled: $DMG"
else
  echo "::warning::$DMG is NOT notarized (no signing credentials or DMG_NOTARIZE=false)." >&2
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ packaged $DMG"
