#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
cd "$PROJECT_DIR"
for ARCHITECTURE in arm64 x86_64; do
    swift build -c release --product ThunderBridge --triple "$ARCHITECTURE-apple-macosx13.0"
done
APP_PATH="$OUTPUT_DIR/雷桥.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/ThunderBridge .build/x86_64-apple-macosx/release/ThunderBridge -output "$APP_PATH/Contents/MacOS/ThunderBridge"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/雷桥-macOS.zip"
bash "$PROJECT_DIR/scripts/build-dmg.sh" "$APP_PATH" "$OUTPUT_DIR"
echo "Created $APP_PATH"
