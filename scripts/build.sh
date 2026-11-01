#!/bin/bash
# 릴리스 빌드 + MacPit.app 번들 조립 (ad-hoc 서명)
#   VERSION=0.2.0 ./scripts/build.sh   → Info.plist 버전 지정 (기본: MacPitCore/Version.swift)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-$(sed -n 's/^public let macpitVersion = "\(.*\)"/\1/p' Sources/MacPitCore/Version.swift)}
swift build -c release 2>&1 | grep -v "ld: warning" | tail -3
BIN=$(swift build -c release --show-bin-path)
APP=build/MacPit.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacPitApp" "$APP/Contents/MacOS/MacPit"
# 앱 안에 데몬·CLI·설치 스크립트 동봉 → DMG 사용자도 앱에서 팬 제어 설치 가능
cp "$BIN/macpitd" "$BIN/macpitctl" "$APP/Contents/MacOS/"
cp scripts/install-daemon.sh scripts/uninstall-daemon.sh "$APP/Contents/Resources/"
cp "$BIN/macpitd" build/macpitd
cp "$BIN/macpitctl" build/macpitctl
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
# 중첩 실행 파일 먼저 서명 후 번들 서명
codesign --force --sign - "$APP/Contents/MacOS/macpitd" "$APP/Contents/MacOS/macpitctl" build/macpitd build/macpitctl
codesign --force --sign - "$APP"
echo "built: $(pwd)/build (v$VERSION)"
