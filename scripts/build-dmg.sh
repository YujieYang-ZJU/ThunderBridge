#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/dist/雷桥.app}"
OUTPUT_DIR="${2:-$PROJECT_DIR/dist}"
[[ -d "$APP_PATH" ]] || { echo "App not found: $APP_PATH" >&2; exit 1; }
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
DMG_PATH="$OUTPUT_DIR/ThunderBridge-v$VERSION-macOS-universal.dmg"
[[ ! -e "$DMG_PATH" ]] || { echo "Output already exists: $DMG_PATH" >&2; exit 1; }
codesign --verify --deep --strict "$APP_PATH"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp/}thunderbridge-dmg.XXXXXX")
DMG_MOUNTED=false
cleanup() {
    if [[ "$DMG_MOUNTED" == true ]]; then
        hdiutil detach "$STAGING_DIR/mounted" -quiet || return
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
# Keep packaging dependencies and compiler caches outside the source tree.
if [[ -n "${DMGBUILD:-}" ]]; then
    DMGBUILD_COMMAND="$DMGBUILD"
else
    python3 -m venv "$STAGING_DIR/venv"
    "$STAGING_DIR/venv/bin/python" -m pip install --disable-pip-version-check --no-cache-dir dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3
    DMGBUILD_COMMAND="$STAGING_DIR/venv/bin/dmgbuild"
fi
swift -module-cache-path "$STAGING_DIR/module-cache" "$PROJECT_DIR/scripts/make-dmg-background.swift" "$STAGING_DIR"
tiffutil -cathidpicheck "$STAGING_DIR/background.png" "$STAGING_DIR/background@2x.png" -out "$STAGING_DIR/background.tiff"
"$DMGBUILD_COMMAND" -s "$PROJECT_DIR/scripts/dmg-settings.py" -D "app=$APP_PATH" -D "background=$STAGING_DIR/background.tiff" "ThunderBridge" "$DMG_PATH"
hdiutil verify "$DMG_PATH"
# Verify the app after packaging, including attributes added by the image builder.
mkdir "$STAGING_DIR/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$STAGING_DIR/mounted" -quiet "$DMG_PATH"
DMG_MOUNTED=true
codesign --verify --deep --strict "$STAGING_DIR/mounted/$(basename "$APP_PATH")"
[[ "$(readlink "$STAGING_DIR/mounted/Applications")" == /Applications ]]
cmp "$APP_PATH/Contents/MacOS/ThunderBridge" "$STAGING_DIR/mounted/$(basename "$APP_PATH")/Contents/MacOS/ThunderBridge"
hdiutil detach "$STAGING_DIR/mounted" -quiet
DMG_MOUNTED=false
echo "Created $DMG_PATH"
