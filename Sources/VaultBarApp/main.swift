import AppKit
import SwiftUI
import VaultBarCore

let arguments = Array(CommandLine.arguments.dropFirst())

// `VaultBar --render-settings out.png`: draws the Settings window with demo vaults, offscreen, for the README.
if arguments.count == 2, arguments[0] == "--render-settings" {
    _ = NSApplication.shared
    let demo = try! JSONDecoder().decode(Config.self, from: Data("""
        {"defaultVault": "Personal", "launchAtLogin": true, "raycastScriptsDir": "~/Raycast",
         "autoLock": {"onSleep": true, "onScreenLock": true, "idleMinutes": 15},
         "vaults": [{"name": "Personal", "imagePath": "~/Vaults/Personal.sparsebundle"},
                    {"name": "Work", "imagePath": "~/Vaults/Work.sparsebundle", "mountPoint": "~/Vaults/mnt/Work",
                     "hidden": true, "readOnly": true}]}
        """.utf8))
    let view = NSHostingView(rootView: SettingsView(controller: AppController(preview: demo)))
    view.frame.size = view.fittingSize
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[1]))
    exit(0)
}

// The `vaultbar` command line: run as `vaultbar` (the cask's symlink), or with a subcommand. `--status` is the
// older spelling of `status`.
let calledAs = CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""
if calledAs == "vaultbar" || arguments.first.map({ CLI.subcommands.contains($0) || ["--status", "-h", "--help"].contains($0) }) == true {
    let cli = arguments.first == "--status" ? ["status"] + arguments.dropFirst()
        : ["-h", "--help"].contains(arguments.first ?? "") ? ["help"] : arguments
    exit(CommandLineTool.run(cli))
}

// The app itself takes only what macOS or the hand-off passes. Anything else is a typo, not a reason to start a
// second menu bar copy.
guard arguments.allSatisfy({ $0.hasPrefix("-psn_") || $0 == "--no-handoff" }) else {
    CommandLineTool.printError(CLI.usage)
    exit(CLIExit.usage.rawValue)
}

// One VaultBar at a time. At login the LaunchAgent copy and a Finder / `open` / login-window-restored copy can
// start together: the first to take the lock wins, the other exits 0 (so launchd doesn't restart it either).
// The bundle-id check also catches an older version without the lock. A copy that is exiting (a hand-off) can
// linger in the running-apps list for a moment, so dead or terminated pids don't count, and the agent copy
// retries for up to 3 s before giving up.
let isAgentCopy = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == AppController.agentLabel
let instanceLock = open(NSTemporaryDirectory() + "com.padina.vaultbar.lock", O_CREAT | O_RDWR, 0o600)
func rivalReason() -> String? {
    let rival = NSRunningApplication.runningApplications(withBundleIdentifier: "com.padina.vaultbar").first {
        $0.processIdentifier != getpid() && !$0.isTerminated && (kill($0.processIdentifier, 0) == 0 || errno == EPERM)
    }
    if let rival { return "another copy is running (pid \(rival.processIdentifier))" }
    if instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) != 0 { return "the instance lock is held" }
    return nil
}
var rival = rivalReason()
for _ in 0..<(isAgentCopy ? 12 : 0) where rival != nil {
    usleep(250_000)
    rival = rivalReason()
}
if let rival {
    log.notice("not starting (\(isAgentCopy ? "agent" : "non-agent", privacy: .public) copy, pid \(getpid())): \(rival, privacy: .public)")
    exit(0)
}
log.notice("\(isAgentCopy ? "agent" : "non-agent", privacy: .public) copy started, pid \(getpid())")

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
