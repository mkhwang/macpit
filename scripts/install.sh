#!/bin/bash
# 소스 설치: 팬 제어 데몬 + ~/Applications/MacPit.app + 로그인 시 자동 실행.
#   sudo ./scripts/install.sh
# DMG/Homebrew 로 설치했다면 이 스크립트 대신 앱의 "팬 제어 설치…" 버튼을 쓴다.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행하세요: sudo $0"; exit 1; }
OWNER_UID=${SUDO_UID:?sudo 로 실행해야 함}
OWNER=$(id -un "$OWNER_UID")
[ -x build/macpitd ] || sudo -u "$OWNER" ./scripts/build.sh

./scripts/install-daemon.sh build/macpitd build/macpitctl "$OWNER_UID"

# 앱: ~/Applications + 로그인 LaunchAgent
HOME_DIR=$(eval echo "~$OWNER")
sudo -u "$OWNER" mkdir -p "$HOME_DIR/Applications" "$HOME_DIR/Library/LaunchAgents"
rm -rf "$HOME_DIR/Applications/MacPit.app"
# 0.1.x(MacMon) 앱·로그인 항목 정리 (히스토리·설정은 MacPit 첫 실행 시 이전됨)
pkill -f "MacMon.app/Contents/MacOS/MacMon" || true
rm -rf "$HOME_DIR/Applications/MacMon.app" "$HOME_DIR/Library/LaunchAgents/com.mkhwang.macmon.plist"
sudo -u "$OWNER" cp -R build/MacPit.app "$HOME_DIR/Applications/"
AGENT="$HOME_DIR/Library/LaunchAgents/com.mkhwang.macpit.plist"
sudo -u "$OWNER" tee "$AGENT" >/dev/null <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.mkhwang.macpit</string>
	<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$HOME_DIR/Applications/MacPit.app</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PL
sleep 1
sudo -u "$OWNER" /usr/local/bin/macpitctl status || true
echo "app installed: $HOME_DIR/Applications/MacPit.app (로그인 시 자동 실행)"
