#!/bin/bash
# 배포 산출물: build/dist/MacPit-<ver>.dmg, .zip, SHA256SUMS
#   VERSION=0.2.0 ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw build/MacPit.app/Contents/Info.plist)
DIST=build/dist; STAGE=build/dmg
rm -rf "$DIST" "$STAGE" && mkdir -p "$DIST" "$STAGE"
cp -R build/MacPit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacPit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/MacPit-$VERSION.dmg" >/dev/null
ditto -c -k --keepParent build/MacPit.app "$DIST/MacPit-$VERSION.zip"
(cd "$DIST" && shasum -a 256 MacPit-$VERSION.dmg MacPit-$VERSION.zip > SHA256SUMS)
cat "$DIST/SHA256SUMS"
