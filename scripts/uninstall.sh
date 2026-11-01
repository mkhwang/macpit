#!/bin/bash
# sudo ./scripts/uninstall.sh — 데몬 정지(팬 system 반납) 후 제거
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행하세요"; exit 1; }
LABEL=com.mkhwang.macmond
launchctl bootout system /Library/LaunchDaemons/$LABEL.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL /usr/local/bin/macmonctl /var/run/macmond.sock
rm -rf "/Library/Application Support/MacMon"
if [ -n "${SUDO_UID:-}" ]; then
  H=$(eval echo "~$(id -un "$SUDO_UID")")
  pkill -f "MacMon.app/Contents/MacOS/MacMon" || true
  rm -rf "$H/Applications/MacMon.app" "$H/Library/LaunchAgents/com.mkhwang.macmon.plist"
fi
echo "removed"
