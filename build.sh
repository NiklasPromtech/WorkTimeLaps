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

# Ad-hoc code-sign the app so macOS is more likely to remember the Screen
# Recording permission across rebuilds (an unsigned binary gets a new
# “identity” each build and re-prompts).
echo "▶ Ad-hoc code-signing…"
codesign --force --sign - "$BUNDLE_DIR"

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
