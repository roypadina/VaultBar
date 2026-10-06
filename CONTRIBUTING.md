# Contributing to VaultBar

Thanks for your interest! Bug reports, feature ideas, docs and code are all welcome.

## Ground rules

- **`main` is protected.** No direct pushes; changes land via Pull Request and are
  reviewed/merged by the maintainer ([@roypadina](https://github.com/roypadina)).
- Be respectful — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep changes focused. One logical change per PR, smallest diff that solves it.
- **Security first.** A password may only ever reach `hdiutil`/`diskutil` through the child's stdin
  (`-stdinpass` / `--stdinpassphrase`). Never add a code path that stores it, logs it, passes it in
  argv or env, or runs a verb that opens an encrypted image without the stdin flag (that pops the
  system password dialog with its "Remember in keychain" box).

## Getting started

```bash
git clone https://github.com/roypadina/VaultBar.git
cd VaultBar
swift test                 # core logic tests
Scripts/package_app.sh     # builds dist/VaultBar.app
```

Requirements: **macOS 14+**, Xcode or the Xcode command line tools (Swift 6).

Install the build to `/Applications` and run it from there (`ditto dist/VaultBar.app /Applications/VaultBar.app`).
`Scripts/package_app.sh` signs with `CODE_SIGN_IDENTITY` if set, else the first code-signing identity in your
keychain, else ad hoc. Ad hoc changes the code hash every build, so the login item may need re-approval after
rebuilds. A self-signed code-signing certificate avoids that.

**Test with throwaway vaults only.** `VAULTBAR_E2E=1 swift test --filter endToEnd` creates, mounts and deletes a
test vault in `.scratch/` (volume `VaultBarTest`).

`Scripts/e2e_launchd.sh` checks that a VaultBar copy is always running through a hand-off to the login agent, an
upgrade (bundle replaced the way brew does) and a crash, sampling every 200 ms. It builds a separate headless variant
(`com.padina.vaultbar.e2e`, executable `VaultBarE2E`, config in `.scratch/`, no vaults, no menu bar item, no URL
scheme), installs its login agent and removes everything again at the end.

## Layout

- `Sources/VaultBarCore` — pure, tested logic: config, `hdiutil` runner and parsing, URL routing, Raycast scripts,
  sync-folder check, auto-lock pause and force decisions.
- `Sources/VaultBarApp` — the AppKit/SwiftUI menu bar app: status item, password popup, auto-lock, Settings,
  New Vault, About.
- `Tests/VaultBarCoreTests` — Swift Testing suite for the core (plus the gated end-to-end test).
- `Assets/icons` — SVG sources for the app and menu bar icons; regenerate the PNG/icns with
  `Scripts/make_icons.sh` (needs `brew install librsvg`).
- `docs/screenshots/settings.png` — rendered offscreen with demo vaults:
  `swift build && .build/debug/VaultBarApp --render-settings docs/screenshots/settings.png`.

## Workflow

1. **Fork** and branch: `git checkout -b feat/my-thing`.
2. Make your change; run `swift test` and try it in the packaged app.
3. Match the surrounding style; no drive-by refactors.
4. Open a **Pull Request** against `main`. CI must be green and the maintainer must approve.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `feat: ...`, `fix: ...`, `docs: ...`.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/roypadina/VaultBar/issues/new/choose).
Never paste a vault password into an issue.
