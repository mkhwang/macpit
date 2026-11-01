#!/bin/bash
# sudo ./scripts/uninstall.sh — 데몬 정지(팬 system 반납) 후 데몬·앱 제거
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행하세요"; exit 1; }
./scripts/uninstall-daemon.sh
if [ -n "${SUDO_UID:-}" ]; then
  OWNER=$(id -un "$SUDO_UID")
  H=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
  pkill -u "$SUDO_UID" -f "MacPit.app/Contents/MacOS/MacPit" || true
  # 사용자 홈 아래는 사용자 권한으로 삭제
  [ -d "$H" ] && sudo -u "$OWNER" rm -rf "$H/Applications/MacPit.app" "$H/Library/LaunchAgents/com.mkhwang.macpit.plist" "$H/Library/LaunchAgents/com.mkhwang.macmon.plist"
fi
echo "removed"
