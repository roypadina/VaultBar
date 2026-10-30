// VaultBar demo: the real PasswordPanel (PasswordPanel.swift, compiled unchanged against the real VaultBarCore) over fake data.
// Nothing is mounted or unlocked and the app is never launched: the panel is only drawn into a bitmap. Status glyphs are the app's own
// Assets/icons PNGs, composed like AppController.statusImage; menu rows copy AppController.showMenu.
import AppKit
import SwiftUI

private let W = Demo.size.width, H = Demo.size.height
private let vaultName = "Work"  // fake; the default vault (Config.defaultVault)

// MARK: the real unlock panel

/// The panel's own content view in a container that takes the keyboard like the real panel does (AppKit-captured window, never shown).
private final class Host: NSViewController {
    let content: NSView, field: NSSecureTextField
    init(content: NSView, field: NSSecureTextField) { self.content = content; self.field = field; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let box = FocusBox(field: field)
        let ring = FocusRing(field: field)
        for v in [content, ring] {  // the overlay goes last: drawn on top of the content
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: box.leadingAnchor), v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
        }
        view = box
    }
}
private final class FocusBox: NSView {
    let field: NSSecureTextField
    init(field: NSSecureTextField) { self.field = field; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {  // PasswordPanel.ask: makeFirstResponder(field); a real field editor puts the caret after the typed text
        guard window?.makeFirstResponder(field) == true else { return }
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0))
    }
}

/// cacheDisplay skips AppKit's focus-ring pass and the field editor's caret, which a real key panel shows on its first responder
/// (PasswordPanel.ask: makeFirstResponder(field)). Drawn the way the Obsidian Vault Git Watcher demo does: accent at 0.5 alpha, 3 pt wide, 3 pt outside the field.
private final class FocusRing: NSView {
    let field: NSSecureTextField
    init(field: NSSecureTextField) { self.field = field; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let f = convert(field.bounds, from: field)
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.5).setStroke()  // the accent the other demos use (not the live system accent)
        let ring = NSBezierPath(roundedRect: f.insetBy(dx: -1.5, dy: -1.5), xRadius: 8.5, yRadius: 8.5)
        ring.lineWidth = 3; ring.stroke()
        // caret: where the field editor ends its text (bullets when typed, the left text edge before the placeholder)
        guard let ed = field.currentEditor() as? NSTextView, let lm = ed.layoutManager, let tc = ed.textContainer else { return }
        let n = lm.numberOfGlyphs
        let end = (n == 0 ? tc.lineFragmentPadding : lm.boundingRect(forGlyphRange: NSRange(location: n - 1, length: 1), in: tc).maxX) + ed.textContainerOrigin.x
        let x = convert(NSPoint(x: end, y: 0), from: ed).x
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSRect(x: x.rounded(), y: f.midY - 7.5, width: 1, height: 15).fill()
    }
}

@MainActor private func descendants<T: NSView>(_ type: T.Type, of v: NSView) -> [T] {
    v.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + descendants(type, of: $0) }
}

/// The unlock prompt with `typed` password characters in the field (the secure field draws them as dots).
@MainActor private func unlockImage(typed: Int) -> CGImage {
    let panel = PasswordPanel()
    panel.configure(vault: vaultName, readOnly: false, message: "Enter the vault password.")  // AppController.swift:487 (message), :486 (vault, mode)
    let content = panel.contentView!
    let title = panel.title                                                                    // PasswordPanel.showMode: "Unlock Work — Read & Write"
    panel.contentView = nil
    let field = descendants(NSSecureTextField.self, of: content).first!
    field.stringValue = String(repeating: "x", count: typed)
    // PasswordPanel.updateHint reads the live keyboard layout and Caps Lock; pin it so the render is the same on every Mac.
    // Font and colour too: Caps Lock at render time would make it semibold + labelColor (PasswordPanel.swift:70-73).
    for label in descendants(NSTextField.self, of: content) where label.font?.pointSize == NSFont.smallSystemFontSize {
        label.stringValue = "Keyboard: ABC"  // PasswordPanel.swift:65 format
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize); label.textColor = .secondaryLabelColor
    }
    let host = Host(content: content, field: field)
    host.preferredContentSize = content.fittingSize
    return captureWindow(controller: host, title: title, styleMask: [.titled], disabledButtons: [.closeButton, .miniaturizeButton, .zoomButton])!
}

// MARK: status glyphs (real assets)

/// AppController.statusImage: locked = the template glyph in the bar's text colour; unlocked = notebook in text colour + the colour badge.
@MainActor private func glyph(unlocked: Bool) -> CGImage {
    let dir = ProcessInfo.processInfo.environment["VB_ASSETS"] ?? "Assets/icons"
    func load(_ name: String) -> CGImage {
        guard let i = NSImage(contentsOfFile: "\(dir)/\(name)@2x.png")?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("missing \(dir)/\(name)") }
        return i
    }
    let px = Int((18 * Demo.scale).rounded()), r = CGRect(x: 0, y: 0, width: px, height: px)
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(load(unlocked ? "menubar-notebook" : "menubar-locked"), in: r)
    c.setBlendMode(.sourceIn); c.setFillColor(CGColor(gray: 1, alpha: 0.95)); c.fill(r)
    c.setBlendMode(.normal)
    if unlocked { c.draw(load("menubar-unlocked"), in: r) }
    return c.makeImage()!
}

// MARK: menu (AppController.showMenu, one unlocked vault, history has one entry)

private let menuRows: [MenuMock.Row] = [
    .item("\(vaultName) (default) — Unlocked", symbol: "lock.open.fill", enabled: false),   // :353 title, :356 image, :357 disabled
    .item("Lock"),                                                                          // :360 command("Lock", .lock, vault)
    .item("Open in Finder"),                                                                // :361
    .separator,                                                                             // :375
    .item("Lock All"),                                                                      // :377, enabled :378 while a vault is unlocked
    .item("Pause Auto-Lock for 1 Hour"),                                                    // :380 (pause not active)
    .item("Last: Unlocked \(vaultName), 9:41 AM", enabled: false),                          // :383 + record() :521, time = date.formatted(.shortened)
    .item("History"),                                                                       // :388
    .separator,
    .item("New Vault…"),                                                                    // :390
    .item("Add Existing Vault…"),                                                           // :391
    .item("Settings…", key: "⌘,"),                                                          // :392
    .separator,
    .item("About VaultBar"),                                                                // :394
    .item("Support on Ko-fi ☕"),                                                            // :395
    .separator,
    .item("Quit VaultBar", key: "⌘Q"),                                                      // :397
]

private let clock941 = Demo.clock, clock942 = "Thu Oct 30 9:42 AM", clock956 = "Thu Oct 30 9:56 AM", clock957 = "Thu Oct 30 9:57 AM"

@MainActor func vaultBarScenes() -> [Scene] {
    let locked = glyph(unlocked: false), unlocked = glyph(unlocked: true)
    let typedMax = 10
    let panels = (0...typedMax).map { unlockImage(typed: $0) }
    let panelSize = CGSize(width: CGFloat(panels[0].width) / Demo.scale, height: CGFloat(panels[0].height) / Demo.scale)
    // NSWindow.center(): horizontally centred, a little above the vertical centre (approximated: 40 % of the free height above the window).
    let panelOrigin = CGPoint(x: ((W - panelSize.width) / 2).rounded(), y: (Demo.barHeight + (H - Demo.barHeight - panelSize.height) * 0.40).rounded())

    // The kit's menu bar takes one SF-Symbol/text item. Reserve an 18 pt blank text slot for the app's real glyph and draw it on top.
    let space = NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width
    let slot = StatusItem(text: String(repeating: " ", count: Int((18 / space).rounded(.up))))
    // The kit lays the bar out from the clock's width, so every scene takes its item frame from the clock it shows.
    let item = Canvas(background: nil).menuBar(app: slot, clock: clock941)        // scene 2
    let glyphCenter = CGPoint(x: item.midX, y: Demo.barHeight / 2)
    let item3 = Canvas(background: nil).menuBar(app: slot, clock: clock942)       // scene 3
    let glyphCenter3 = CGPoint(x: item3.midX, y: Demo.barHeight / 2)
    let menu = Canvas.menuFrame(menuRows, under: item3)
    let rowFrames = MenuMock.frames(menuRows).map { $0.offsetBy(dx: menu.minX, dy: menu.minY) }
    func rowPoint(_ i: Int) -> CGPoint { CGPoint(x: menu.minX + 100, y: rowFrames[i].midY) }

    /// Menu bar with the app's glyph; `pressed` = the item is highlighted (button down, or its menu open).
    func bar(unlocked isUnlocked: Bool, clock: String, pressed: Bool = false) -> Canvas {
        let c = Canvas()
        let frame = c.menuBar(app: slot, appActive: pressed, clock: clock)
        c.draw(isUnlocked ? unlocked : locked, in: CGRect(x: frame.midX - 9, y: Demo.barHeight / 2 - 9, width: 18, height: 18))
        return c
    }
    func down(_ t: Double, _ at: Double) -> Bool { t >= at && t < at + 0.14 }

    // 1. locked: the template notebook (AppController.refresh: "menubar-locked" when no vault is unlocked)
    let s1 = Scene(name: "locked", duration: 1.8, caption: "Your locked vault sits in the menu bar") { _ in
        bar(unlocked: false, clock: clock941).image
    }

    // 2. a plain click toggles the default vault (StatusClick.toggleDefault): the password panel opens at once, ten characters are typed,
    //    Return closes it, the mount finishes a moment later and the glyph gets the unlocked badge.
    let path2 = CursorPath(start: CGPoint(x: W * 0.72, y: H * 0.46), moves: [.init(t0: 0.10, t1: 0.70, to: glyphCenter)], clicks: [0.85])
    let typeStart = 1.5, typeStep = 0.14, returnAt = 3.2, mountedAt = 3.5
    let s2 = Scene(name: "unlock", duration: 4.0, caption: "Click, type the password. It is never stored.") { t in
        let isOpen = t >= 0.85 && t < returnAt + 0.06
        let c = bar(unlocked: t >= mountedAt, clock: clock941, pressed: down(t, 0.85))
        if isOpen {
            let typed = min(typedMax, max(0, Int(((t - typeStart) / typeStep).rounded(.down)) + 1))
            c.window(panels[t < typeStart ? 0 : typed], at: panelOrigin, radius: 16, alpha: CGFloat(ramp(t, 0.85, 0.93) * (1 - ramp(t, returnAt, returnAt + 0.06))))
        }
        let click = path2.click(t)
        c.cursor(at: path2.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 1.15, 1.40))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 3. right-click (Control-click) opens the menu: StatusClick.menu. Hover follows the cursor; a click elsewhere closes it at once.
    let path3 = CursorPath(start: CGPoint(x: W * 0.74, y: H * 0.44),
                           moves: [.init(t0: 0.10, t1: 0.70, to: glyphCenter3),
                                   .init(t0: 1.20, t1: 1.70, to: rowPoint(1)),
                                   .init(t0: 2.40, t1: 2.85, to: CGPoint(x: W * 0.30, y: H * 0.55))],
                           clicks: [0.85, 3.00])
    let s3 = Scene(name: "menu", duration: 3.4, caption: "Right-click: Lock, Open in Finder, Lock All") { t in
        let fadeIn = ramp(t, 0.85, 0.97), fadeOut = 1 - ramp(t, 3.00, 3.12)
        let open = t >= 0.85 && fadeOut > 0
        let c = bar(unlocked: true, clock: clock942, pressed: open)
        if open { c.menu(menuRows, under: item3, hover: path3.position(t), alpha: CGFloat(min(fadeIn, fadeOut))) }
        let click = path3.click(t)
        c.cursor(at: path3.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 3.15, 3.35))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 4. auto-lock (Config.AutoLock: sleep, screen lock, idle 15 min): 15 minutes without input, the vault locks by itself.
    let s4 = Scene(name: "auto-lock", duration: 2.8, caption: "Sleep, screen lock or idle: it locks itself") { t in
        t < 0.9 ? bar(unlocked: true, clock: clock956).image : bar(unlocked: false, clock: clock957).image
    }
    return [s1, s2, s3, s4]
}

@main struct VaultBarDemo {
    @MainActor static func main() {
        _ = NSApplication.shared  // PasswordPanel is an NSPanel: AppKit must be up before the scenes build it (Demo.run asks for it too late)
        Demo.run(scenes: vaultBarScenes())
    }
}
