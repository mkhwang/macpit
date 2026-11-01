#!/bin/bash
# root 데몬(macmond) 설치 + 앱 설치 + 로그인 시 자동 실행.
#   sudo ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행하세요: sudo $0"; exit 1; }
OWNER_UID=${SUDO_UID:?sudo 로 실행해야 함}
OWNER=$(id -un "$OWNER_UID")
[ -x build/macmond ] || sudo -u "$OWNER" ./scripts/build.sh

LABEL=com.mkhwang.macmond
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

launchctl bootout system "$PLIST" 2>/dev/null || true
install -m 755 -o root -g wheel build/macmond "$BIN"
install -m 755 build/macmonctl /usr/local/bin/macmonctl 2>/dev/null || { mkdir -p /usr/local/bin && install -m 755 build/macmonctl /usr/local/bin/macmonctl; }
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

# 앱: ~/Applications + 로그인 LaunchAgent
HOME_DIR=$(eval echo "~$OWNER")
sudo -u "$OWNER" mkdir -p "$HOME_DIR/Applications" "$HOME_DIR/Library/LaunchAgents"
rm -rf "$HOME_DIR/Applications/MacMon.app"
sudo -u "$OWNER" cp -R build/MacMon.app "$HOME_DIR/Applications/"
AGENT="$HOME_DIR/Library/LaunchAgents/com.mkhwang.macmon.plist"
sudo -u "$OWNER" tee "$AGENT" >/dev/null <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.mkhwang.macmon</string>
	<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$HOME_DIR/Applications/MacMon.app</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PL
sleep 1
sudo -u "$OWNER" /usr/local/bin/macmonctl status || true
echo "app installed: $HOME_DIR/Applications/MacMon.app (로그인 시 자동 실행)"
