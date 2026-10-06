/// Panic-lock hotkey presets (Carbon key codes and modifier masks; no Accessibility permission needed).
public struct PanicHotkey: Equatable, Sendable {
    public let id: String
    public let title: String
    public let keyCode: UInt32
    public let modifiers: UInt32

    // Carbon: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000; kVK_ANSI_L 0x25, kVK_ANSI_K 0x28.
    public static let presets = [
        PanicHotkey(id: "ctrl-opt-cmd-L", title: "⌃⌥⌘L", keyCode: 0x25, modifiers: 0x1000 | 0x800 | 0x100),
        PanicHotkey(id: "ctrl-opt-cmd-K", title: "⌃⌥⌘K", keyCode: 0x28, modifiers: 0x1000 | 0x800 | 0x100),
        PanicHotkey(id: "ctrl-shift-cmd-L", title: "⌃⇧⌘L", keyCode: 0x25, modifiers: 0x1000 | 0x200 | 0x100),
        PanicHotkey(id: "opt-shift-cmd-L", title: "⌥⇧⌘L", keyCode: 0x25, modifiers: 0x800 | 0x200 | 0x100),
    ]
    public static let `default` = presets[0]

    /// nil for "off" (or an unknown id).
    public static func preset(_ id: String) -> PanicHotkey? { presets.first { $0.id == id } }
}
