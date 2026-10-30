# VaultBar demo — storyboard (12.0 s, loops)

What it shows: how VaultBar works (a plain click asks for the password, the password is never stored, the menu, auto-lock) and why it is
worth installing (an open vault locks itself).

Real code: `PasswordPanel` (`Sources/VaultBarApp/PasswordPanel.swift`) compiled unchanged together with the real `Sources/VaultBarCore`
(built as a static module so `import VaultBarCore` resolves). The panel is instantiated and filled with the app's own
`configure(vault:readOnly:message:)`, its real content view is handed to the kit's window chrome. Status glyphs are the app's real
`Assets/icons/menubar-{locked,notebook,unlocked}@2x.png`, composed the way `AppController.statusImage` does. Menu rows copy
`AppController.showMenu` (titles, order, disabled rows). The password field's focus ring and caret are drawn by the scene (cacheDisplay skips both; accent 0.5 alpha, 3 pt, like the Obsidian Vault Git Watcher demo). Fake data: one vault "Work" (default), password typed as dots, clock 9:41–9:57.

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | locked | 0.0 | 1.8 | Menu bar only, clock 9:41. Status item: the locked notebook glyph (template, white). | Your locked vault sits in the menu bar |
| 2 | unlock | 1.8 | 4.0 | Cursor glides to the icon, click: the item flashes, the real unlock panel ("Unlock Work — Read & Write", segmented mode switch, "Enter the vault password.", Password field, Cancel / Unlock) appears at once. Ten dots are typed, Return: the panel closes at once, the glyph turns to the unlocked notebook with the amber badge 0.3 s later. | Click, type the password. It is never stored. |
| 3 | menu | 5.8 | 3.4 | Clock 9:42. Cursor glides to the icon, right-click: menu opens at once ("Work (default) — Unlocked", Lock, Open in Finder, Lock All, Pause Auto-Lock for 1 Hour, Last: Unlocked Work, 9:41 AM, History, New Vault…, Add Existing Vault…, Settings…, About, Support, Quit). Hover follows to "Lock". Click on the desktop: menu closes at once. | Right-click: Lock, Open in Finder, Lock All |
| 4 | auto-lock | 9.2 | 2.8 | No cursor. Unlocked glyph at clock 9:56; at 0.9 s the clock reads 9:57 (15 idle minutes) and the glyph flips back to locked. Holds locked (≈ scene 1: clean loop). | Sleep, screen lock or idle: it locks itself |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s (never two pills at once); the last 0.2 s
dissolves into scene 1's first frame (clean loop).
Cursor: system arrow (`NSCursor.arrow`), eased glides, click = dip + white ripple; visible only while it points at something.
Render: `./render.sh` (swiftc: real VaultBarCore static lib, kit + scene + real PasswordPanel.swift; 30 fps frames; encode).
Never mounts or unlocks anything, never launches VaultBar: the panel is only ever drawn into a bitmap.
