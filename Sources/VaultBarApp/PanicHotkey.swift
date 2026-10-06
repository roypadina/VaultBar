@preconcurrency import Carbon
import VaultBarCore

extension AppController {
    /// (Re)registers the panic-lock hotkey from the config ("off" unregisters it).
    func applyPanicHotkey() {
        let hotkey = PanicHotkey.preset(config.panicHotkey)
        if !PanicHotkeyMonitor.shared.register(hotkey, action: { [weak self] in self?.panicLock() }), let hotkey {
            log.error("panic hotkey \(hotkey.title, privacy: .public) is taken by another app")
            record("Panic hotkey \(hotkey.title) is taken by another app")
        }
    }
}

/// Carbon `RegisterEventHotKey`: a global hotkey without Accessibility or Input Monitoring permission.
@MainActor
final class PanicHotkeyMonitor {
    static let shared = PanicHotkeyMonitor()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// false if macOS refused the hotkey (usually: another app owns it).
    func register(_ hotkey: PanicHotkey?, action: @escaping () -> Void) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        self.action = action
        guard let hotkey else { return true }
        installHandler()
        let id = EventHotKeyID(signature: 0x5642_4152, id: 1) // 'VBAR'
        return RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in PanicHotkeyMonitor.shared.action?() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}
