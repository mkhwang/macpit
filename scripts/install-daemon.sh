#!/bin/bash
# 팬 제어 데몬(macmond) + macmonctl 설치. root 로 실행.
#   install-daemon.sh <macmond 경로> <macmonctl 경로> <소켓 소유자 uid>
# install.sh(소스 설치)와 MacMon.app("팬 제어 설치…" 버튼, 관리자 암호 요청)이 공통으로 쓴다.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "root 로 실행해야 함"; exit 1; }
SRC_D=${1:?macmond 경로}; SRC_C=${2:?macmonctl 경로}; OWNER_UID=${3:?uid}
[[ "$OWNER_UID" =~ ^[0-9]+$ ]] || { echo "uid 가 숫자가 아님: $OWNER_UID"; exit 1; }

LABEL=com.mkhwang.macmond
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

# 기존 데몬 정지 → 정지 시 팬을 macOS 에 반납함
launchctl bootout system "$PLIST" 2>/dev/null || true
mkdir -p /Library/PrivilegedHelperTools /usr/local/bin
# 앱 번들(사용자 쓰기 가능) 경로를 직접 실행하지 않도록 root 소유 위치로 복사
install -m 755 -o root -g wheel "$SRC_D" "$BIN"
install -m 755 -o root -g wheel "$SRC_C" /usr/local/bin/macmonctl
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
	<dict><key>MACMON_OWNER_UID</key><string>$OWNER_UID</string></dict>
	<key>StandardOutPath</key><string>/var/log/macmond.log</string>
	<key>StandardErrorPath</key><string>/var/log/macmond.log</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
echo "daemon installed: $LABEL"
