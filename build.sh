#!/bin/bash
# Build WorkTimeLaps.app from source without needing an Xcode project.
# Requires: Xcode Command Line Tools (`xcode-select --install`).

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
# -O   = optimize
# No explicit -target; swiftc defaults to the host architecture.
swiftc -O \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework AVKit \
    -framework Charts \
    -framework CoreGraphics \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
    -framework UserNotifications \
    Sources/*.swift

echo "▶ Copying Info.plist…"
cp Resources/Info.plist "$CONTENTS_DIR/Info.plist"

echo "▶ Writing PkgInfo…"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# Ad-hoc code-sign the app so macOS is more likely to remember the Screen
# Recording permission across rebuilds (an unsigned binary gets a new
# “identity” each build and re-prompts).
echo "▶ Ad-hoc code-signing…"
codesign --force --sign - "$BUNDLE_DIR"

echo ""
echo "✅ Built $BUNDLE_DIR"
echo ""
echo "Next steps:"
echo "  1. Open it:          open $BUNDLE_DIR"
echo "  2. Grant permission: System Settings → Privacy & Security → Screen Recording"
echo "     (toggle WorkTimeLaps on, then relaunch the app)"
echo "  3. Look at the top-right menu bar for a ○ icon."
