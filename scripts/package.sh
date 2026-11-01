#!/bin/bash
# 배포 산출물: build/dist/MacMon-<ver>.dmg, .zip, SHA256SUMS
#   VERSION=0.2.0 ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw build/MacMon.app/Contents/Info.plist)
DIST=build/dist; STAGE=build/dmg
rm -rf "$DIST" "$STAGE" && mkdir -p "$DIST" "$STAGE"
cp -R build/MacMon.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacMon $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/MacMon-$VERSION.dmg" >/dev/null
ditto -c -k --keepParent build/MacMon.app "$DIST/MacMon-$VERSION.zip"
(cd "$DIST" && shasum -a 256 MacMon-$VERSION.dmg MacMon-$VERSION.zip > SHA256SUMS)
cat "$DIST/SHA256SUMS"
