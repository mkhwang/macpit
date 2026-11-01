#!/bin/bash
# 릴리스 빌드 + MacMon.app 번들 조립 (ad-hoc 서명)
#   VERSION=0.2.0 ./scripts/build.sh   → Info.plist 버전 지정 (기본: MacMonCore/Version.swift)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-$(sed -n 's/^public let macmonVersion = "\(.*\)"/\1/p' Sources/MacMonCore/Version.swift)}
swift build -c release 2>&1 | grep -v "ld: warning" | tail -3
BIN=$(swift build -c release --show-bin-path)
APP=build/MacMon.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacMonApp" "$APP/Contents/MacOS/MacMon"
# 앱 안에 데몬·CLI·설치 스크립트 동봉 → DMG 사용자도 앱에서 팬 제어 설치 가능
cp "$BIN/macmond" "$BIN/macmonctl" "$APP/Contents/MacOS/"
cp scripts/install-daemon.sh scripts/uninstall-daemon.sh "$APP/Contents/Resources/"
cp "$BIN/macmond" build/macmond
cp "$BIN/macmonctl" build/macmonctl
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
# 중첩 실행 파일 먼저 서명 후 번들 서명
codesign --force --sign - "$APP/Contents/MacOS/macmond" "$APP/Contents/MacOS/macmonctl" build/macmond build/macmonctl
codesign --force --sign - "$APP"
echo "built: $(pwd)/build (v$VERSION)"
