import AppKit
import SwiftUI
import VaultBarCore

// `VaultBar --status`: print what the app sees (from `hdiutil info` only) and exit, no UI.
if CommandLine.arguments.contains("--status") {
    do {
        let config = try Config.load() ?? Config.seed
        let mounted = HDIUtil.mounted()
        for vault in config.vaults {
            let state = mounted.mountPoint(of: vault).map { "unlocked at \($0)" } ?? "locked"
            print("\(vault.name)\(vault.name == config.defaultVault ? " (default)" : ""): \(state)")
        }
        exit(0)
    } catch {
        print("config error: \(error)")
        exit(1)
    }
}

// `VaultBar --render-settings out.png`: draws the Settings window with demo vaults, offscreen, for the README.
if let index = CommandLine.arguments.firstIndex(of: "--render-settings"), index + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let demo = try! JSONDecoder().decode(Config.self, from: Data("""
        {"defaultVault": "Personal", "launchAtLogin": true, "raycastScriptsDir": "~/Raycast",
         "autoLock": {"onSleep": true, "onScreenLock": true, "idleMinutes": 15},
         "vaults": [{"name": "Personal", "imagePath": "~/Vaults/Personal.sparsebundle"},
                    {"name": "Work", "imagePath": "~/Vaults/Work.sparsebundle"}]}
        """.utf8))
    let view = NSHostingView(rootView: SettingsView(controller: AppController(preview: demo)))
    view.frame.size = view.fittingSize
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
