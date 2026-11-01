## Install

**Homebrew**
```bash
brew tap mkhwang/macmon https://github.com/mkhwang/macmon
brew install --cask mkhwang/macmon/macmon
```

**DMG** — download `MacMon-<version>.dmg` below and drag MacMon to Applications.
MacMon is free and not notarized by Apple, so macOS blocks the first launch. Run once:
```bash
xattr -dr com.apple.quarantine /Applications/MacMon.app
```
or open **System Settings → Privacy & Security → Open Anyway**.

Fan control needs a small root helper: open the MacMon panel and click **팬 제어 설치… (Install fan control)**. Monitoring and cache cleanup work without it.

Verify downloads with `SHA256SUMS`.
