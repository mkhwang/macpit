# Security

MacPit has two parts with different privileges.

| Part | Runs as | Can do |
|---|---|---|
| `MacPit.app` | your user | read SMC sensors, read system stats, delete files in whitelisted cache folders under your home, run `docker ... prune` |
| `macpitd` (optional) | root, LaunchDaemon | write fan keys (`F{n}Md`, `F{n}Tg`) to the SMC. Nothing else. |

## What the root helper does and does not do

- Listens only on `/var/run/macpitd.sock`, mode `0600`, owned by the user who installed it. Other users cannot talk to it.
- Accepts two commands: `status` and `setConfig` (fan mode, percent, curve, target temperature). It never runs shell commands, never touches files other than its own config (`/Library/Application Support/MacPit/config.json`) and log (`/var/log/macpitd.log`).
- Returns fans to macOS on exit, on SIGTERM, on sensor read failure, and at startup if a previous crash left them forced.
- Forces 100% above the safety temperature (default 95°C) regardless of mode.
- The installer copies the helper from the app bundle to `/Library/PrivilegedHelperTools/` (root-owned), so later changes to the app bundle cannot change what runs as root until you reinstall.
- The flip side: *installing* runs the helper and script from the app bundle, which your user account can modify. Malware already running as your user could tamper with the bundle before you click **팬 제어 설치…** and get root when you enter the password. This is the same trust you give any app that asks for an admin password; signed (Developer ID) builds would close it and are not available for this free project. Only click install right after downloading a release you verified with `SHA256SUMS`.
- The helper accepts requests only from root and the installing user (socket mode 0600). All config values are clamped and non-finite numbers are rejected, reads have a 3-second deadline, and at most 4 requests are handled at once.

## Cache cleanup

- Only hard-coded paths under your home directory. A path is refused if any part of it is a symlink.
- Folder contents are removed, the folder itself is kept.
- "Caution" items (Maven local repo, Trash, unused Docker images, stopped containers, unused volumes) are never selected by default and never run by scheduled cleanup.
- Scheduled cleanup skips a target while its tool is running (Gradle, JetBrains IDEs, Xcode, VS Code, Maven).

## Distribution

Releases are built by GitHub Actions from the tagged source and ad-hoc signed (no paid Apple Developer ID). Check `SHA256SUMS` on the release page, or build from source with `./scripts/build.sh`.

## Reporting

Please open a private advisory: **Security → Report a vulnerability** on the GitHub repo.
