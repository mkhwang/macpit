## Install

**Homebrew**
```bash
brew tap mkhwang/macpit https://github.com/mkhwang/macpit
brew trust mkhwang/macpit     # Homebrew 5+: allow casks from this tap
brew install --cask mkhwang/macpit/macpit
```

**DMG** — download `MacPit-<version>.dmg` below and drag MacPit to Applications.
MacPit is free and not notarized by Apple, so macOS blocks the first launch. Run once:
```bash
xattr -dr com.apple.quarantine /Applications/MacPit.app
```
or open **System Settings → Privacy & Security → Open Anyway**.

Fan control needs a small root helper: open the MacPit panel and click **팬 제어 설치… (Install fan control)**. Monitoring and cache cleanup work without it.

**Upgrading from MacMon 0.1.x**: launch MacPit once (history and settings move over), click **팬 제어 설치…** to replace the old helper, then delete `MacMon.app`. Homebrew: `brew uninstall --cask macmon && brew untap mkhwang/macmon` first.

Verify downloads with `SHA256SUMS`.
