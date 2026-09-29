#!/bin/bash
# Builds and runs the test suite: every source file except the app's
# main.swift, plus Tests/*.swift, compiled into one command-line binary.
#
# Tests run against a throwaway data folder (WORKTIMELAPS_DATA_DIR) and
# never touch ~/Movies/WorkTimeLaps. They run in a DST-observing time zone
# so the work-day boundary tests cover clock changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SOURCES=()
for f in Sources/*.swift; do
    [ "$(basename "$f")" = "main.swift" ] || SOURCES+=("$f")
done

echo "▶ Building tests…"
swiftc \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$WORK_DIR/WorkTimeLapsTests" \
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
    "${SOURCES[@]}" Tests/*.swift

echo "▶ Running tests…"
mkdir -p "$WORK_DIR/data"
WORKTIMELAPS_DATA_DIR="$WORK_DIR/data" TZ="Europe/Stockholm" "$WORK_DIR/WorkTimeLapsTests"
