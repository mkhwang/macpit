#!/bin/bash
# 팬 제어 데몬(macpitd) + macpitctl 설치. root 로 실행.
#   install-daemon.sh <macpitd 경로> <macpitctl 경로> <소켓 소유자 uid>
# install.sh(소스 설치)와 MacPit.app("팬 제어 설치…" 버튼, 관리자 암호 요청)이 공통으로 쓴다.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "root 로 실행해야 함"; exit 1; }
SRC_D=${1:?macpitd 경로}; SRC_C=${2:?macpitctl 경로}; OWNER_UID=${3:?uid}
[[ "$OWNER_UID" =~ ^[0-9]+$ ]] || { echo "uid 가 숫자가 아님: $OWNER_UID"; exit 1; }

LABEL=com.mkhwang.macpitd
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

# 기존 데몬 정지 → 정지 시 팬을 macOS 에 반납함
launchctl bootout system "$PLIST" 2>/dev/null || true

# 0.1.x(MacMon) 구 데몬 정리 + 팬 설정 이전 (새 설정이 없을 때만)
OLD=com.mkhwang.macmond
if [ -e "/Library/LaunchDaemons/$OLD.plist" ] || [ -e "/Library/PrivilegedHelperTools/$OLD" ]; then
  launchctl bootout system "/Library/LaunchDaemons/$OLD.plist" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/$OLD.plist" "/Library/PrivilegedHelperTools/$OLD" /usr/local/bin/macmonctl /var/run/macmond.sock
  echo "legacy daemon removed: $OLD"
fi
if [ -f "/Library/Application Support/MacMon/config.json" ] && [ ! -L "/Library/Application Support/MacMon/config.json" ] \
   && [ ! -e "/Library/Application Support/MacPit/config.json" ]; then
  install -d -m 755 -o root -g wheel "/Library/Application Support/MacPit"
  install -m 644 -o root -g wheel "/Library/Application Support/MacMon/config.json" "/Library/Application Support/MacPit/config.json"
fi
rm -rf "/Library/Application Support/MacMon"
mkdir -p /Library/PrivilegedHelperTools /usr/local/bin
# 앱 번들(사용자 쓰기 가능) 경로를 직접 실행하지 않도록 root 소유 위치로 복사
install -m 755 -o root -g wheel "$SRC_D" "$BIN"
install -m 755 -o root -g wheel "$SRC_C" /usr/local/bin/macpitctl
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>Program</key><string>$BIN</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>EnvironmentVariables</key>
	<dict><key>MACPIT_OWNER_UID</key><string>$OWNER_UID</string></dict>
	<key>StandardOutPath</key><string>/var/log/macpitd.log</string>
	<key>StandardErrorPath</key><string>/var/log/macpitd.log</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
# 로그 회전: 1MB 넘으면 압축, 3개 보관
cat > /etc/newsyslog.d/macpitd.conf <<NS
# logfilename          [owner:group]  mode count size(KB) when flags
/var/log/macpitd.log   root:wheel     644  3     1024     *    JN
NS
chmod 644 /etc/newsyslog.d/macpitd.conf
launchctl bootstrap system "$PLIST"
echo "daemon installed: $LABEL"
