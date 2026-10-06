import AppKit
import Carbon
import VaultBarCore

/// The unlock prompt. A non-activating panel can become the key window, and so take the keyboard, without
/// VaultBar being the active app. Activation is only a request on macOS 14+ (another app, e.g. Raycast after
/// `open vaultbar://...`, may keep it), so the panel never depends on it.
final class PasswordPanel: NSPanel {
    /// The mount mode, visible and switchable before unlocking (⌘R): icon + "<vault> — Read-Only" + a segmented control.
    private let modeIcon = NSImageView()
    private let modeTitle = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["Read & Write", "Read-Only"], trackingMode: .selectOne, target: nil, action: nil)
    private var vaultName = ""
    private let message = NSTextField(wrappingLabelWithString: "")
    private let field = NSSecureTextField()
    /// Caps Lock and the keyboard layout: the usual reasons a right password is "wrong".
    private let hint = NSTextField(labelWithString: "")
    private var completion: ((Secret?, Bool) -> Void)?
    private var flagsMonitor: Any?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        field.placeholderString = "Password"
        field.target = self
        field.action = #selector(submit)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelOperation(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let unlock = NSButton(title: "Unlock", target: self, action: #selector(submit))
        unlock.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, unlock])
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        modeTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        modeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let header = NSStackView(views: [modeIcon, modeTitle])
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Mount mode")
        mode.toolTip = "⌘R switches"
        let stack = NSStackView(views: [header, mode, message, field, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [header, message, field, hint, buttons] { view.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        contentView = stack
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateHint() } }
    }

    private func updateHint() {
        var parts: [String] = []
        if NSEvent.modifierFlags.contains(.capsLock) { parts.append("Caps Lock is on") }
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            parts.append("Keyboard: \(Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String)")
        }
        hint.stringValue = parts.joined(separator: " · ")
        hint.textColor = parts.first == "Caps Lock is on" ? .systemOrange : .secondaryLabelColor
    }

    /// Fills the panel without showing it.
    func configure(vault: String, readOnly: Bool, message text: String) {
        vaultName = vault
        mode.selectedSegment = readOnly ? 1 : 0
        showMode()
        message.stringValue = text
        updateHint()
    }

    private var isReadOnly: Bool { mode.selectedSegment == 1 }
    private var modeName: String { isReadOnly ? "Read-Only" : "Read & Write" }

    private func showMode() {
        title = "Unlock \(vaultName) — \(modeName)"
        modeTitle.stringValue = "\(vaultName) — \(modeName)"
        modeIcon.image = NSImage(systemSymbolName: isReadOnly ? "lock.doc.fill" : "lock.open.fill", accessibilityDescription: nil)
        modeIcon.contentTintColor = isReadOnly ? .systemBlue : NSColor(srgbRed: 0.97, green: 0.72, blue: 0.29, alpha: 1)
        modeTitle.textColor = isReadOnly ? .systemBlue : .labelColor
        field.setAccessibilityLabel("Password for \(vaultName), \(modeName)")
    }

    /// Clicking a segment shouldn't leave the keyboard there: back to the password field.
    @objc private func modeChanged() {
        showMode()
        makeFirstResponder(field)
        NSAccessibility.post(element: field, notification: .announcementRequested,
                             userInfo: [.announcement: modeName, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Shows the prompt ready to type, preset to `readOnly`; `completion` gets the password and the mode chosen
    /// (nil password: Cancel / Esc).
    func ask(vault: String, readOnly: Bool, message text: String, completion: @escaping (Secret?, Bool) -> Void) {
        configure(vault: vault, readOnly: readOnly, message: text)
        self.completion = completion
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.updateHint()
                return event
            }
        }
        NSApp.activate() // nice to have; the panel takes the keyboard either way
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        // A closing status menu or a late activation can move focus once more; take it back on the next turn.
        DispatchQueue.main.async { [self] in
            guard isVisible else { return }
            makeKeyAndOrderFront(nil)
            makeFirstResponder(field)
            // VaultBar is usually not the active app, so VoiceOver may not notice the panel on its own.
            NSAccessibility.post(element: field, notification: .announcementRequested, userInfo: [
                .announcement: "Unlock \(vault), \(modeName). \(text) Command R switches the mode.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    @objc private func submit() {
        // The field's String can't be wiped (see Secret); clear it and pass on only the byte copy.
        finish(Secret(field.stringValue))
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ secret: Secret?) {
        field.stringValue = ""
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        orderOut(nil)
        guard let completion else { secret?.wipe(); return }
        self.completion = nil
        completion(secret, isReadOnly)
    }

    /// ⌘R switches the mode; ⌘V / ⌘A / ⌘X / ⌘C work even while another app stays active and its menu bar owns
    /// the shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "r" {
            mode.selectedSegment = isReadOnly ? 0 : 1
            modeChanged()
            return true
        }
        let actions: [String: Selector] = ["v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                                           "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:))]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let action = event.charactersIgnoringModifiers.flatMap({ actions[$0] }),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
