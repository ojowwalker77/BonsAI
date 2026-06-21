#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BonsAI"
PRODUCT_NAME="Composer"   # SwiftPM executable output; the staged .app binary is renamed to APP_NAME
BUNDLE_ID="dev.jow.BonsAI"
MIN_SYSTEM_VERSION="26.0"
# Sparkle EdDSA public key — the public half of the pair from Sparkle's `generate_keys`. Safe to commit
# (only the private key is secret; it lives in the SPARKLE_PRIVATE_KEY CI secret). Fill this in after
# running setup; until then the updater stays idle (no SUPublicEDKey is emitted, so no insecure feed).
SPARKLE_PUBLIC_KEY="RwEq55AfbXnJMuIxXySJMyzspkDrUla/TRFKZrGQ6PI="
BUILD_CONFIGURATION="release"

# Normal launches should exercise the same optimized, compact binary users get. Keep an explicit
# debug lane for LLDB without quietly shipping or profiling the much larger Debug product.
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  BUILD_CONFIGURATION="debug"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

# App version: CI injects the exact tag via BONSAI_VERSION; local builds derive it from the most recent
# git tag (falling back to a dev marker). Feeds CFBundleShortVersionString/CFBundleVersion below — the
# values Sparkle compares to decide whether a published release is newer than what's installed.
VERSION="${BONSAI_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${VERSION#v}"
fi
VERSION="${VERSION:-0.0.0-dev}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build -c "$BUILD_CONFIGURATION"
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PRODUCT_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/Composer_ComposerApp.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
# SwiftPM's release linker product can still carry debug symbol records. They are unnecessary in
# the staged app bundle and `strip -S` removes only those records, not executable code.
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  /usr/bin/strip -S "$APP_BINARY"
fi
chmod +x "$APP_BINARY"
# Stage SwiftPM's resource bundle in the canonical Contents/Resources. Bundle.appResources (our
# crash-proof resolver) looks here first, and it's the codesign-clean location the release signs and
# notarizes — so local builds exercise the exact layout users download. Do NOT move it back to the
# .app root: that is non-standard for a signed app and only ever worked by accident locally.
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  mkdir -p "$APP_CONTENTS/Resources"
  cp -R "$RESOURCE_BUNDLE" "$APP_CONTENTS/Resources/"
fi

# Sparkle auto-updater. SwiftPM links Sparkle but does not bundle it into our hand-staged .app, so copy
# Sparkle.framework into Contents/Frameworks and add the loader rpath that resolves @rpath/Sparkle...
# at runtime. This is bundling only — it does not touch the board/dock layout CLAUDE.md guards. The
# framework is signed (inside-out) by the release workflow; local unsigned builds run it as-is.
SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build" -path '*macos*/Sparkle.framework' -type d 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found under .build — run 'swift package resolve' first." >&2
  exit 1
fi
mkdir -p "$APP_CONTENTS/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_CONTENTS/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"

# App icon: bake AppIcon.icns from a 1024×1024 source PNG if present (drop yours at icon/BonsAI.png).
# macOS Dock icons sit inside an ~80% safe area with a transparent margin, so a full-bleed square
# looks oversized next to native icons. If ImageMagick is present, scale the art to the Apple grid
# (824 in 1024, centered) so it matches; otherwise the raw source is used as-is.
ICON_SRC="$ROOT_DIR/icon/BonsAI.png"
if [[ -f "$ICON_SRC" ]]; then
  WORK="$(mktemp -d)"
  ICON_MASTER="$ICON_SRC"
  if command -v magick >/dev/null 2>&1; then
    # Only pad a FULL-BLEED source. A pre-margined icon is used as-is so we never double-pad it.
    content_w="$(magick "$ICON_SRC" -trim +repage -format "%w" info: 2>/dev/null || echo 1024)"
    if [[ "${content_w:-1024}" -ge 1000 ]]; then
      magick "$ICON_SRC" -resize 824x824 -background none -gravity center -extent 1024x1024 "$WORK/master.png" \
        && ICON_MASTER="$WORK/master.png"
    fi
  fi
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET" "$APP_CONTENTS/Resources"
  for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET" -o "$APP_CONTENTS/Resources/AppIcon.icns"
fi

# Only emit SUPublicEDKey when a key is configured. Sparkle treats an empty value as a misconfigured,
# insecure feed; omitting the key instead leaves the updater cleanly idle on un-set-up local builds.
SPARKLE_KEY_ENTRY=""
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  SPARKLE_KEY_ENTRY="  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>https://github.com/kiwi-init/BonsAI/releases/latest/download/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
$SPARKLE_KEY_ENTRY
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  bundle|--bundle|build|--build)
    # Build + stage the .app only, no launch. Used by CI and the release workflow.
    echo "Staged $APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|bundle|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
