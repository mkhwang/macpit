# Homebrew cask (이 저장소 자체가 tap):
#   brew tap mkhwang/macmon https://github.com/mkhwang/macmon
#   brew install --cask mkhwang/macmon/macmon
# version·sha256 은 릴리스 워크플로가 갱신한다.
cask "macmon" do
  version "0.1.0"
  sha256 "45a72d3196b37e1e55a39c3387bfce6883a57173b023a8abc6ccea36e8f281af"

  url "https://github.com/mkhwang/macmon/releases/download/v#{version}/MacMon-#{version}.dmg"
  name "MacMon"
  desc "Menu bar monitor with fan control and developer cache cleanup for Apple Silicon"
  homepage "https://github.com/mkhwang/macmon"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MacMon.app"

  # 공증(유료 Developer ID) 없이 배포하므로 Gatekeeper 격리 속성 제거
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/MacMon.app"]
  end

  uninstall quit:      "com.mkhwang.macmon",
            launchctl: "com.mkhwang.macmond",
            delete:    [
              "/Library/PrivilegedHelperTools/com.mkhwang.macmond",
              "/Library/LaunchDaemons/com.mkhwang.macmond.plist",
              "/usr/local/bin/macmonctl",
            ]

  zap trash: [
    "~/Library/Application Support/MacMon",
    "~/Library/Preferences/com.mkhwang.macmon.plist",
    "/Library/Application Support/MacMon",
  ]

  caveats <<~EOS
    Fan control needs a root helper. Open the MacMon panel and click
    "팬 제어 설치…" (Install fan control). Monitoring and cleanup work without it.
  EOS
end
