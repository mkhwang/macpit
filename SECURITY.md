# Security

MacMon has two parts with different privileges.

| Part | Runs as | Can do |
|---|---|---|
| `MacMon.app` | your user | read SMC sensors, read system stats, delete files in whitelisted cache folders under your home, run `docker ... prune` |
| `macmond` (optional) | root, LaunchDaemon | write fan keys (`F{n}Md`, `F{n}Tg`) to the SMC. Nothing else. |

## What the root helper does and does not do

- Listens only on `/var/run/macmond.sock`, mode `0600`, owned by the user who installed it. Other users cannot talk to it.
- Accepts two commands: `status` and `setConfig` (fan mode, percent, curve, target temperature). It never runs shell commands, never touches files other than its own config (`/Library/Application Support/MacMon/config.json`) and log (`/var/log/macmond.log`).
- Returns fans to macOS on exit, on SIGTERM, on sensor read failure, and at startup if a previous crash left them forced.
- Forces 100% above the safety temperature (default 95°C) regardless of mode.
- The installer copies the helper from the app bundle to `/Library/PrivilegedHelperTools/` (root-owned), so later changes to the app bundle cannot change what runs as root until you reinstall.

## Cache cleanup

- Only hard-coded paths under your home directory. Symlinks that point outside home are refused.
- Folder contents are removed, the folder itself is kept.
- "Caution" items (Maven local repo, Trash, stopped containers, unused volumes) are never selected by default and never run by scheduled cleanup.

## Distribution

Releases are built by GitHub Actions from the tagged source and ad-hoc signed (no paid Apple Developer ID). Check `SHA256SUMS` on the release page, or build from source with `./scripts/build.sh`.

## Reporting

Please open a private advisory: **Security → Report a vulnerability** on the GitHub repo.
