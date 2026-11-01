# Security

MacPit has two parts with different privileges.

| Part | Runs as | Can do |
|---|---|---|
| `MacPit.app` | your user | read SMC sensors, read system stats, delete files in whitelisted cache folders under your home, run `docker ... prune` |
| `macpitd` (optional) | root, LaunchDaemon | write fan keys (`F{n}Md`, `F{n}Tg`) to the SMC. Nothing else. |

## What the root helper does and does not do

- Listens only on `/var/run/macpitd.sock`, mode `0600`, owned by the user who installed it. Other users cannot talk to it.
- Accepts two commands: `status` and `setConfig` (fan mode, percent, curve, target temperature). It never runs shell commands, never touches files other than its own config (`/Library/Application Support/MacPit/config.json`) and log (`/var/log/macpitd.log`).
- Returns fans to macOS on exit, on SIGTERM, on sensor read failure, and at startup if a previous crash left them forced. On SIGTERM the control loop is stopped before fans are released, so it cannot re-force them during shutdown.
- Forces 100% when the CPU **or** GPU reaches the safety temperature (default 95°C, cannot be set above 100°C) regardless of mode.
- Only writes the fan keys `F{n}Md` and `F{n}Tg`. A fan whose minimum RPM cannot be read is treated as read-only, so 0% can never mean "fan stopped".
- The installer copies the helper from the app bundle to `/Library/PrivilegedHelperTools/` (root-owned), so later changes to the app bundle cannot change what runs as root until you reinstall.
- The flip side: *installing* runs the helper and script from the app bundle, which your user account can modify. Malware already running as your user could tamper with the bundle before you click **팬 제어 설치…** and get root when you enter the password. This is the same trust you give any app that asks for an admin password; signed (Developer ID) builds would close it and are not available for this free project. To keep that window small, the app asks to update the helper only when the helper itself changed (`macpitDaemonVersion`), not on every app release. Be suspicious of an unexpected password prompt.
- The helper accepts requests only from root and the installing user (socket mode 0600). All config values are clamped and non-finite numbers are rejected, reads have a 3-second deadline, and at most 4 requests are handled at once.

## Release pipeline

- Releases are built by GitHub Actions only from `v*` tags that point to a commit already on `main`; the workflow refuses other tags before it builds or updates the Homebrew cask.
- Third-party actions are pinned to a commit SHA.
- Builds are ad-hoc signed, not notarized. The cask and `SHA256SUMS` carry the checksum computed by the same workflow.

## Cache cleanup

- Only hard-coded paths under your home directory. A path is refused if any part of it is a symlink.
- Folder contents are removed, the folder itself is kept.
- "Caution" items (Maven local repo, Trash, unused Docker images, stopped containers, unused volumes) are never selected by default and never run by scheduled cleanup.
- Scheduled cleanup skips a target while its tool is running (Gradle, JetBrains IDEs, Xcode, VS Code, Maven).

## Distribution

Releases are built by GitHub Actions from the tagged source and ad-hoc signed (no paid Apple Developer ID). Check `SHA256SUMS` on the release page, or build from source with `./scripts/build.sh`.

## Reporting

Please open a private advisory: **Security → Report a vulnerability** on the GitHub repo.
