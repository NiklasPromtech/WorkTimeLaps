#!/bin/bash
# Build WorkTimeLaps.app from source without needing an Xcode project.
# Requires: Xcode Command Line Tools (`xcode-select --install`).
#
#   ./build.sh           build WorkTimeLaps.app in this folder
#   ./build.sh install   …and copy it to /Applications (recommended, so the
#                        login item keeps pointing at the right place)

set -euo pipefail

APP_NAME="WorkTimeLaps"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Resolve paths relative to this script so `./build.sh` works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "▶ Cleaning previous build…"
rm -rf "$BUNDLE_DIR"

echo "▶ Creating bundle structure…"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "▶ Compiling Swift sources…"
# -O       optimize
# -target  host architecture, macOS 14 deployment target (matches
#          LSMinimumSystemVersion, and makes the compiler reject newer APIs)
swiftc -O \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework AVKit \
    -framework Charts \
    -framework CoreGraphics \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
    -framework Security \
    -framework ServiceManagement \
    -framework UserNotifications \
    Sources/*.swift

echo "▶ Copying Info.plist and icon…"
cp Resources/Info.plist "$CONTENTS_DIR/Info.plist"
cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

echo "▶ Writing PkgInfo…"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# Code signing. macOS ties privacy permissions (Screen Recording) and the
# keychain item's access list to the app's signing identity. With a real
# certificate — a free Apple Development one from Xcode will do — they
# survive rebuilds. Signed ad hoc, every rebuild looks like a new app.
#
#   CODESIGN_IDENTITY="Apple Development: …" ./build.sh   use this identity
#   CODESIGN_IDENTITY=- ./build.sh                        force ad-hoc signing
#
# By default the first Apple Development or Developer ID Application
# identity in your keychain is used, if there is one.
IDENTITY="${CODESIGN_IDENTITY:-}"
IDENTITY_NAME="$IDENTITY"
if [ -z "$IDENTITY" ]; then
    FOUND="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Apple Development|Developer ID Application): ' | head -1 || true)"
    if [ -n "$FOUND" ]; then
        IDENTITY="$(echo "$FOUND" | awk '{print $2}')"
        IDENTITY_NAME="$(echo "$FOUND" | sed -E 's/^[^"]*"(.*)"$/\1/')"
    fi
fi

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
    echo "▶ Code-signing ad hoc (no signing certificate found)…"
    codesign --force --sign - "$BUNDLE_DIR"
    echo "  Note: macOS ties Screen Recording access to this exact build. After a"
    echo "  rebuild, remove WorkTimeLaps under System Settings → Privacy & Security →"
    echo "  Screen & System Audio Recording (–) and grant access again."
else
    echo "▶ Code-signing as $IDENTITY_NAME…"
    codesign --force --sign "$IDENTITY" "$BUNDLE_DIR"
fi

echo ""
echo "✅ Built $BUNDLE_DIR"

if [ "${1:-}" = "install" ]; then
    echo "▶ Installing to /Applications…"
    # Quit a running copy first (lets it finish the current video cleanly).
    if pgrep -x "$APP_NAME" >/dev/null; then
        osascript -e 'tell application id "com.niklas.worktimelaps" to quit' >/dev/null 2>&1 || true
        while pgrep -x "$APP_NAME" >/dev/null; do sleep 0.5; done
    fi
    rm -rf "/Applications/$BUNDLE_DIR"
    ditto "$BUNDLE_DIR" "/Applications/$BUNDLE_DIR"
    echo "✅ Installed /Applications/$BUNDLE_DIR"
    APP_PATH="/Applications/$BUNDLE_DIR"
else
    APP_PATH="$BUNDLE_DIR"
fi

echo ""
echo "Next steps:"
echo "  1. Open it:          open \"$APP_PATH\""
echo "  2. Follow the welcome window: API key, Screen Recording access, login item."
echo "  3. Look for the ◉ icon in the menu bar."
