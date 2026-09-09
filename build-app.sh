#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${CODEXMETER_BUILD_DIR:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
swift build --disable-sandbox --scratch-path "$BUILD_DIR" -c release
BIN_DIR="$(swift build --disable-sandbox --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
APP="$PWD/Codex Meter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexMeter" "$APP/Contents/MacOS/CodexMeter"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$BUILD_DIR/CodexMeter.iconset"
swift Tools/MakeIcon.swift "$BUILD_DIR/CodexMeter.iconset" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Application prête : $APP"
