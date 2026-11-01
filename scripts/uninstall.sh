#!/bin/bash
# sudo ./scripts/uninstall.sh — 데몬 정지(팬 system 반납) 후 데몬·앱 제거
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행하세요"; exit 1; }
./scripts/uninstall-daemon.sh
if [ -n "${SUDO_UID:-}" ]; then
  H=$(eval echo "~$(id -un "$SUDO_UID")")
  pkill -f "MacPit.app/Contents/MacOS/MacPit" || true
  rm -rf "$H/Applications/MacPit.app" "$H/Library/LaunchAgents/com.mkhwang.macpit.plist" "$H/Library/LaunchAgents/com.mkhwang.macmon.plist"
fi
echo "removed"
