# Changelog

All notable changes to VaultBar are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-10-06

### Fixed
- `--unregister-login-item` no longer mistakes "unknown" for "nothing to lock": an unreadable config or a failing `hdiutil info` now exits 1 and changes nothing, instead of removing the login item (which would stop a running copy that may hold unlocked vaults).

### Changed
- README: unregister locks what it can; any vault that can't be locked keeps the login item; `--force` force-locks busy ones.

## [0.2.1] - 2026-10-06

### Changed
- **Always exactly one copy running, never zero.** The login item is now a classic LaunchAgent; the old SMAppService agent pinned the binary and broke after Homebrew upgrades. Hand-offs and upgrades use an ack protocol: the old copy quits only after the new one confirms.
- Unlock prompt shows and switches the mode ("Read & Write" / "Read-Only"); ⌘R toggles.
- Control-click on the menu bar icon opens the menu (was: unlock prompt).
- `vaultbar --unregister-login-item [--force]` locks every vault before removing the login item.

### Notes
- Upgrading from 0.2.0 or older may leave VaultBar stopped for 1-2 s once; later upgrades are gap-free.

## [0.2.0] - 2026-10-06

### Added
- **Private mount**: per-vault mount folder (created on unlock, removed on lock or eject), optionally hidden from Finder.
- **Read-only unlock**: per-vault default, ⌥ "Unlock Read-Only…", `?readonly=1`, CLI `--readonly`.
- **`vaultbar` CLI**: `status [--json]`, `path`, `lock`, `unlock [--readonly] [--wait s]`, `open`. No password path; exit codes 0/1/2/3/64.
- **Notifications and history**: generic notifications for auto-locks, a pre-force warning with "Keep unlocked 15 min", failed locks; last 50 events kept in memory.
- **Panic lock**: global hotkey (default ⌃⌥⌘L, forces), ⌥-click = Lock All, `vaultbar://lockall`.
- **Change password** via `diskutil image chpass`.
- Password prompt: Caps Lock and keyboard-layout hints, VoiceOver announcement and labels.

### Fixed
- Hand-off race with the login agent; relaunch fallback when the app is moved.

## [0.1.3] - 2026-10-06

### Fixed
- Login agent breaking after a Homebrew upgrade (launchd exit 78): VaultBar re-registers its login agent from its own bundle on every launch outside launchd.
- Hand-off to the agent now verifies a VaultBar process is running, else keeps an unsupervised copy (never ends up not running).

### Added
- Upgrades are detected automatically: within ~30 s of `brew upgrade` (once idle) the running copy restarts on the new version.

### Notes
- Upgrading from 0.1.2 or older: after `brew upgrade`, quit VaultBar from its menu and open it once.

## [0.1.2] - 2026-10-06

### Added
- Open vaults in Finder: menu "Open in Finder" / "Unlock & Open…", `vaultbar://open/<name>`, and a Raycast "Open <Vault>" script (unlocks first if needed).
- Setting "Open in Finder after unlocking" (off by default).

### Changed
- Raycast scripts are synced on every launch.
- A copy started from Finder or `open` hands over to the supervised login agent once idle, so crash restart works right away.
- Docs: URL action table, slug naming.

## [0.1.1] - 2026-10-05

### Added
- Quit while a vault is unlocked asks: Lock All & Quit / Quit / Cancel.
- Single-instance guard.

### Changed
- Always running: the login item is now a LaunchAgent that restarts VaultBar if it crashes (not after a deliberate Quit).
- Password prompt is focused and ready to type from a click, the menu, a `vaultbar://` link or Raycast.
- Unlocked state is an amber open padlock in the menu bar; paused shows an orange warning badge.
- Icon metadata stripped.

## [0.1.0] - 2026-10-05

First release.

### Added
- Lock/unlock encrypted APFS sparse-bundle vaults from the menu bar (left-click = default vault, right-click = menu).
- Password popup; the password goes to `hdiutil` on stdin only and is never stored.
- Auto-lock on sleep, screen lock and idle, with a 1-hour pause.
- Multiple vaults, New Vault…, Add Existing Vault…, URL scheme, optional Raycast script commands.

### Notes
- Ad-hoc signed, not notarized: if macOS blocks the first launch, clear quarantine on the app.

[Unreleased]: https://github.com/roypadina/VaultBar/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/roypadina/VaultBar/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/roypadina/VaultBar/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/roypadina/VaultBar/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/roypadina/VaultBar/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/roypadina/VaultBar/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/roypadina/VaultBar/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/roypadina/VaultBar/releases/tag/v0.1.0
