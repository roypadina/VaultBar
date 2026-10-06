# Security Policy

## Reporting a Vulnerability

VaultBar handles the passwords of encrypted disk images, so security reports are taken seriously.
Please **do not** open a public issue for security problems.

Instead, use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on this repository).

You'll get an acknowledgement within a few days. Once a fix is available it will be released
and the report disclosed, with credit unless you prefer otherwise.

## Scope

VaultBar runs entirely on-device and makes no network connections. The encryption itself is macOS's
(DiskImages, AES-256). Relevant areas:

- how the password travels: the popup and New Vault form, `Secret`, and the stdin pipe to `hdiutil` / `diskutil`
  (it must never be stored, logged, put in argv/env/clipboard, or trigger the system password dialog);
- auto-lock (sleep, screen lock, idle, pause) failing to lock when it should;
- the `vaultbar://` URL scheme, the `vaultbar` command line (neither may ever accept a password) and the generated
  Raycast scripts;
- private mount folders (created only right before unlock, removed after lock) and read-only / hidden mounts;
- Change Password (`diskutil image chpass`, both passwords on stdin only);
- the config file `~/.config/vaultbar/vaults.json` (no secrets, mode 600).
