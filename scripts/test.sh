#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR_PATH" == */CommandLineTools ]]; then
    TEST_FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
    swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib" "$@"
else
    swift test --disable-xctest --enable-swift-testing "$@"
fi
