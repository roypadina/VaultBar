<div align="center">

<img src="docs/AppIcon-1024.png" alt="VaultBar app icon" width="160">

# VaultBar

### Your encrypted vaults, one click from the menu bar.

A small native **macOS** menu bar app that locks and unlocks encrypted disk-image vaults
(AES-256 APFS sparse bundles), and locks them again on sleep, screen lock or idle.
The password is never stored anywhere.

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![CI](https://github.com/roypadina/VaultBar/actions/workflows/ci.yml/badge.svg)](https://github.com/roypadina/VaultBar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?logo=opensourceinitiative&logoColor=white)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Stars](https://img.shields.io/github/stars/roypadina/VaultBar?style=social)](https://github.com/roypadina/VaultBar/stargazers)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-F16061?logo=ko-fi&logoColor=white)](https://ko-fi.com/roypadina)

<br>

<img src="docs/screenshots/settings.png" alt="VaultBar Settings: two vaults, auto-lock options, launch at login and the Raycast scripts folder" width="420">

</div>

---

## Features

- **One click** — left-click the menu bar icon to lock or unlock your default vault. Right-click for every vault
  (Unlock… / Lock, **Open in Finder** or **Unlock & Open…**), Lock All, New Vault…, Add Existing Vault…, Settings….
- **Open in Finder after unlocking** (optional setting), or per vault with Open / `vaultbar://open`.
- **Password popup** that never saves anything: no Keychain, no "remember password", no clipboard.
- **Auto-lock**, for every vault:
  - on **sleep**: forced, immediately;
  - on **screen lock**: clean unmount; if a file is still open, forced after 30 s, but only if the screen is still locked;
  - after **N idle minutes**: clean unmount; if busy, forced after 60 s, but only if you're still away.
- **Pause auto-lock for 1 hour** — for long unattended jobs that work inside a vault (idle only counts keyboard and
  mouse). Sleep still locks. The icon gets a warning badge; the pause ends after an hour, on Resume, or on quit.
- **New Vault…** creates an encrypted AES-256 APFS sparse bundle, warns about weak passwords and about folders that
  sync to a cloud (iCloud Drive, Desktop & Documents, `~/Library/CloudStorage`, Syncthing, Synology Drive).
- **Add Existing Vault…** for any encrypted `.sparsebundle` or `.dmg` (unencrypted images are rejected).
- **URL scheme** and optional **Raycast Script Commands**.
- **Always running**: the login item is a LaunchAgent inside the app, so macOS starts VaultBar at login and
  restarts it if it ever crashes (not after you choose Quit). Only one copy runs at a time; if you start VaultBar
  yourself (Finder, a link), it hands over to that supervised copy as soon as it's idle. No Dock icon.
- **Quit asks first** while a vault is unlocked, since auto-lock stops while VaultBar is closed:
  **Lock All & Quit**, **Quit** or **Cancel**.

Menu bar icon: a monochrome notebook with a closed padlock when everything is locked; an **amber open padlock** as
soon as any vault is unlocked (however it was mounted: VaultBar, Finder, Terminal); an **orange warning badge** while
auto-lock is paused.

## Install

> **Requires macOS 14 Sonoma or newer.**

```bash
brew install --cask roypadina/tap/vaultbar
```

**Not notarized.** VaultBar is ad hoc signed (no paid Apple Developer ID), so macOS may block the first launch. Either
right-click it in `/Applications` → **Open** (then **Open Anyway** in System Settings → Privacy & Security),
or clear quarantine once:

```bash
xattr -dr com.apple.quarantine /Applications/VaultBar.app
```

Or download `VaultBar.zip` from the [latest release](https://github.com/roypadina/VaultBar/releases/latest),
unzip it and move `VaultBar.app` to `/Applications`.

## Usage

1. Click the menu bar icon → **New Vault…** (or **Add Existing Vault…**).
2. **Save the password in your password manager first.** There is no recovery key.
3. Left-click the icon to unlock or lock. The password prompt is ready to type right away (also when opened from
   Raycast or a `vaultbar://` link); Enter unlocks, Esc cancels. The vault mounts in Finder like any disk.
4. Once per new vault, stop Spotlight from indexing it (VaultBar shows the command with a Copy button):
   `sudo mdutil -i off "/Volumes/<volume name>"`.

If a vault is busy when you lock it, VaultBar asks before forcing it. Forcing can lose unsaved changes in open apps.

## Config

`~/.config/vaultbar/vaults.json` (mode 600, never holds a password). Settings edits it for you:

```json
{
  "defaultVault": "Personal",
  "autoLock": { "onSleep": true, "onScreenLock": true, "idleMinutes": 15 },
  "launchAtLogin": true,
  "raycastScriptsDir": "~/Raycast",
  "openAfterUnlock": false,
  "vaults": [
    { "name": "Personal", "imagePath": "~/Vaults/Personal.sparsebundle" },
    { "name": "Work", "imagePath": "~/Vaults/Work.sparsebundle" }
  ]
}
```

- `idleMinutes: 0` turns idle locking off. `raycastScriptsDir` is optional (no scripts without it).
- `openAfterUnlock: true` opens the vault in Finder after every unlock: the menu bar click, the menu's Unlock…,
  `vaultbar://unlock` and the Raycast Unlock script. Default `false`.
- Vaults are matched by their image file, so a volume that macOS renamed to `Personal 1` still shows the right state.
- Removing a vault in Settings only removes it from the list. VaultBar never deletes an image file.

## URL scheme

```
vaultbar://unlock/<name>
vaultbar://lock/<name>
vaultbar://toggle/<name>
vaultbar://open/<name>
```

The name is URL-encoded (`My%20Vault`); an empty name means the default vault.

- **unlock** shows the password popup; it does nothing if the vault is already unlocked. With `openAfterUnlock`,
  Finder opens the vault afterwards.
- **lock** locks (asks before forcing a busy vault). **toggle** locks or unlocks.
- **open** opens the vault in Finder; if it is locked, it asks for the password first, then opens it.
  Cancel does nothing.

## Raycast

Pick your Raycast script directory in **Settings → Raycast Script Commands**. VaultBar then keeps three scripts per
vault there, **Unlock**, **Lock** and **Open** (`vaultbar-unlock-<slug>.sh`, `vaultbar-lock-<slug>.sh`,
`vaultbar-open-<slug>.sh`). The slug is the vault name in lowercase, with spaces and symbols turned into dashes
(e.g. `My Vault` → `my-vault`). VaultBar updates the scripts on every launch and when you add, rename or remove a
vault. Each script only runs `open "vaultbar://unlock|lock|open/<name>"`; the password goes into VaultBar's popup,
never through Raycast. VaultBar only ever deletes scripts it wrote itself (marked
`# @raycast.packageName VaultBar`).

## Security model

- **The password is never stored**: not on disk, in the Keychain, in the config, in logs, in process arguments,
  environment variables or the clipboard.
- It reaches `hdiutil attach -stdinpass` / `diskutil image --stdinpassphrase create` only through a pipe on the child
  process's stdin, closed right after writing. An empty password is refused before any tool runs, so the system's
  own disk-image password dialog (with its "Remember password in my keychain" box) never appears.
- Password bytes are zeroed after use. Best effort: the Swift `String` the text field hands over can't be wiped.
- No "change password": `hdiutil chpass` doesn't work on encrypted sparse bundles.
- Lock events are logged (vault name and reason only) under the `com.padina.vaultbar` subsystem:
  `log show --predicate 'subsystem == "com.padina.vaultbar"' --info --last 1h`.
- Encryption is macOS's own (DiskImages, AES-256). VaultBar is a front end; it makes no network connections.

## Build from source

Requires Xcode or the Xcode command line tools (Swift 6).

```bash
git clone https://github.com/roypadina/VaultBar.git
cd VaultBar
swift test
Scripts/package_app.sh               # writes dist/VaultBar.app
ditto dist/VaultBar.app /Applications/VaultBar.app
open /Applications/VaultBar.app
```

`RELEASE=1 Scripts/package_app.sh` also writes `dist/VaultBar.zip`. `Scripts/make_icons.sh` regenerates the icons
from `Assets/icons/*.svg` (needs `brew install librsvg`). An end-to-end test with a throwaway vault in `.scratch/`:
`VAULTBAR_E2E=1 swift test --filter endToEnd`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Uninstall

```bash
brew uninstall --zap --cask vaultbar
```

Or turn off **Launch at login** in Settings, quit it, drag `/Applications/VaultBar.app` to the Trash, and delete
`~/.config/vaultbar`. Your vault images stay where they are.

## Support

If VaultBar keeps your private files one click away (and locked when you walk off), you can support its
development — it's optional and always appreciated.

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/roypadina)

A ⭐ on the repo helps just as much.

## License

[MIT](LICENSE) © Roy Padina
