# Homebrew cask (이 저장소 자체가 tap):
#   brew tap mkhwang/macpit https://github.com/mkhwang/macpit
#   brew trust mkhwang/macpit   # Homebrew 5+: 비공식 tap 허용
#   brew install --cask mkhwang/macpit/macpit
# version·sha256 은 릴리스 워크플로가 갱신한다.
cask "macpit" do
  version "0.3.1"
  sha256 "6a4a4c0f2c07396c1bb7f32a865aa710c46d043ab4bd59b6a36673ab765de478"

  url "https://github.com/mkhwang/macpit/releases/download/v#{version}/MacPit-#{version}.dmg"
  name "MacPit"
  desc "Menu bar monitor with fan control and developer cache cleanup for Apple Silicon"
  homepage "https://github.com/mkhwang/macpit"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "MacPit.app"

  # 공증(유료 Developer ID) 없이 배포하므로 Gatekeeper 격리 속성 제거
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/MacPit.app"]
  end

  # upgrade 때도 uninstall 이 실행되므로 root 데몬은 여기서 건드리지 않는다
  # (건드리면 업그레이드마다 sudo 암호 + 팬 제어 끊김 + 앱에서 재설치 암호).
  # 데몬은 앱 설정 → "팬 제어 데몬 제거" 또는 `brew uninstall --zap` 으로 제거 (macmond = 0.1.x 잔여물).
  uninstall quit: "com.mkhwang.macpit"

  zap launchctl: ["com.mkhwang.macpitd", "com.mkhwang.macmond"],
      delete:    [
        "/etc/newsyslog.d/macpitd.conf",
        "/Library/LaunchDaemons/com.mkhwang.macmond.plist",
        "/Library/LaunchDaemons/com.mkhwang.macpitd.plist",
        "/Library/PrivilegedHelperTools/com.mkhwang.macmond",
        "/Library/PrivilegedHelperTools/com.mkhwang.macpitd",
        "/usr/local/bin/macmonctl",
        "/usr/local/bin/macpitctl",
      ],
      trash:     [
        "/Library/Application Support/MacPit",
        "~/Library/Application Support/MacMon",
        "~/Library/Application Support/MacPit",
        "~/Library/Preferences/com.mkhwang.macmon.plist",
        "~/Library/Preferences/com.mkhwang.macpit.plist",
      ]

  caveats <<~EOS
    Fan control needs a root helper. Open the MacPit panel and click
    "팬 제어 설치…" (Install fan control). Monitoring and cleanup work without it.

    To remove the root helper, use MacPit 설정 → "팬 제어 데몬 제거" before
    uninstalling, or run: brew uninstall --zap --cask macpit
  EOS
end
