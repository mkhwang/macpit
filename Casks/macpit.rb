# Homebrew cask (이 저장소 자체가 tap):
#   brew tap mkhwang/macpit https://github.com/mkhwang/macpit
#   brew trust mkhwang/macpit   # Homebrew 5+: 비공식 tap 허용
#   brew install --cask mkhwang/macpit/macpit
# version·sha256 은 릴리스 워크플로가 갱신한다.
cask "macpit" do
  version "0.2.1"
  sha256 "60b34f447378927eb2ac29d71415517007ed73c938d242d2451904d1bb11cdb9"

  url "https://github.com/mkhwang/macpit/releases/download/v#{version}/MacPit-#{version}.dmg"
  name "MacPit"
  desc "Menu bar monitor with fan control and developer cache cleanup for Apple Silicon"
  homepage "https://github.com/mkhwang/macpit"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MacPit.app"

  # 공증(유료 Developer ID) 없이 배포하므로 Gatekeeper 격리 속성 제거
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/MacPit.app"]
  end

  uninstall quit:      "com.mkhwang.macpit",
            launchctl: ["com.mkhwang.macpitd", "com.mkhwang.macmond"],
            delete:    [
              "/Library/PrivilegedHelperTools/com.mkhwang.macpitd",
              "/Library/LaunchDaemons/com.mkhwang.macpitd.plist",
              "/usr/local/bin/macpitctl",
              "/etc/newsyslog.d/macpitd.conf",
              # 0.1.x(MacMon) 잔여물
              "/Library/PrivilegedHelperTools/com.mkhwang.macmond",
              "/Library/LaunchDaemons/com.mkhwang.macmond.plist",
              "/usr/local/bin/macmonctl",
            ]

  zap trash: [
    "~/Library/Application Support/MacPit",
    "~/Library/Preferences/com.mkhwang.macpit.plist",
    "/Library/Application Support/MacPit",
    "~/Library/Application Support/MacMon",
    "~/Library/Preferences/com.mkhwang.macmon.plist",
  ]

  caveats <<~EOS
    Fan control needs a root helper. Open the MacPit panel and click
    "팬 제어 설치…" (Install fan control). Monitoring and cleanup work without it.
  EOS
end
