import AppKit

/// Real windows from a menu-bar-only app (MBX-15): Dock icon and menu bar while one is open, back to
/// `.accessory` when the last one closes. The unlock prompt is an `NSPanel`, which can't become main, so it doesn't count.
@MainActor
final class AccessoryWindows: NSObject, NSWindowDelegate {
    static let shared = AccessoryWindows()

    func show(_ window: NSWindow) {
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        // Forceful: a user action, and on macOS 14+ the front app can refuse the activate() request (window opens behind).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        keepFront(window)
    }

    /// shortcut: ~0.5 s after the .accessory → .regular switch macOS hands activation back to the previous app (traced in
    /// PullPing: Settings behind Ghostex, no click). Take it back once unless the user clicked elsewhere meanwhile; drop when macOS stops.
    /// Limit: a keyboard switch (⌘-Tab, a launcher hotkey), or a click in our own window that opens another app, within the
    /// 1.5 s is pulled back once. nil = Sparkle's update window.
    func keepFront(_ window: NSWindow?) {
        var clicked = false, done = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in clicked = true }
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !clicked, !done, NSApp.activationPolicy() == .regular, window?.isVisible ?? true else { return }
                done = true
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            monitor.map(NSEvent.removeMonitor)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}
