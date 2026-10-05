import AppKit
import VaultBarCore

/// The unlock prompt. A non-activating panel can become the key window, and so take the keyboard, without
/// VaultBar being the active app. Activation is only a request on macOS 14+ (another app, e.g. Raycast after
/// `open vaultbar://...`, may keep it), so the panel never depends on it.
final class PasswordPanel: NSPanel {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let field = NSSecureTextField()
    private var completion: ((Secret?) -> Void)?

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
        let stack = NSStackView(views: [message, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [message, field, buttons] { view.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        contentView = stack
    }

    /// Shows the prompt ready to type; `completion` gets the password, or nil on Cancel / Esc.
    func ask(vault: String, message text: String, completion: @escaping (Secret?) -> Void) {
        title = "Unlock \(vault)"
        message.stringValue = text
        self.completion = completion
        NSApp.activate() // nice to have; the panel takes the keyboard either way
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        // A closing status menu or a late activation can move focus once more; take it back on the next turn.
        DispatchQueue.main.async { [self] in
            guard isVisible else { return }
            makeKeyAndOrderFront(nil)
            makeFirstResponder(field)
        }
    }

    @objc private func submit() {
        // The field's String can't be wiped (see Secret); clear it and pass on only the byte copy.
        finish(Secret(field.stringValue))
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ secret: Secret?) {
        field.stringValue = ""
        orderOut(nil)
        guard let completion else { secret?.wipe(); return }
        self.completion = nil
        completion(secret)
    }

    /// ⌘V / ⌘A / ⌘X / ⌘C even while another app stays active and its menu bar owns the shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
