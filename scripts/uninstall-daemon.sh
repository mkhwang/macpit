#!/bin/bash
# 팬 제어 데몬 제거. root 로 실행. 정지 시 데몬이 팬을 macOS 에 반납한다.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "root 로 실행해야 함"; exit 1; }
LABEL=com.mkhwang.macpitd
launchctl bootout system /Library/LaunchDaemons/$LABEL.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL /usr/local/bin/macpitctl /var/run/macpitd.sock
rm -rf "/Library/Application Support/MacPit"
rm -f /etc/newsyslog.d/macpitd.conf
# 0.1.x(MacMon) 잔여물
launchctl bootout system /Library/LaunchDaemons/com.mkhwang.macmond.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.mkhwang.macmond.plist /Library/PrivilegedHelperTools/com.mkhwang.macmond /usr/local/bin/macmonctl /var/run/macmond.sock
rm -rf "/Library/Application Support/MacMon"
echo "daemon removed"
