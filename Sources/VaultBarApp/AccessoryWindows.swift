import AppKit
import OSLog

/// Real windows from a menu-bar-only app (MBX-15): Dock icon and menu bar while one is open, back to
/// `.accessory` when the last one closes. The unlock prompt is an `NSPanel`, which can't become main, so it doesn't count.
@MainActor
final class AccessoryWindows: NSObject, NSWindowDelegate {
    static let shared = AccessoryWindows()
    static let log = Logger(subsystem: "com.padina.vaultbar", category: "activation")

    func show(_ window: NSWindow) {
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        // Forceful: a user action, and on macOS 14+ the front app can refuse the activate() request (window opens behind).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        keepFront(window)
    }

    /// shortcut: ~0.5 s after the .accessory → .regular switch macOS hands activation back to the previous app (traced:
    /// Settings behind Ghostex, no click). Take it back once, within 1.5 s of the show, and only if there was no click or key
    /// press anywhere since (asked of the window server when activation goes, so no event monitor can lose the race: a click in
    /// Edge stole focus back, traced); drop when macOS stops. nil = Sparkle's update window.
    func keepFront(_ window: NSWindow?) {
        let shown = Date()
        var done = false
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(shown)
                let input = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
                    .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
                guard !done, elapsed < 1.5, input > elapsed, NSApp.activationPolicy() == .regular, window?.isVisible ?? true else { return }
                done = true
                Self.log.notice("keepFront: took activation back from \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-", privacy: .public) \(Int(elapsed * 1000)) ms after showing \(window?.title ?? "the update window", privacy: .public)")
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NotificationCenter.default.removeObserver(observer) }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}
