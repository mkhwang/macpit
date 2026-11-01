#!/bin/bash
# 릴리스 빌드 + MacMon.app 번들 조립 (ad-hoc 서명)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | grep -v "ld: warning" | tail -3
BIN=$(swift build -c release --show-bin-path)
APP=build/MacMon.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacMonApp" "$APP/Contents/MacOS/MacMon"
cp "$BIN/macmond" build/macmond
cp "$BIN/macmonctl" build/macmonctl
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --force --sign - build/macmond build/macmonctl >/dev/null 2>&1
echo "built: $(pwd)/build"
