import AppKit
import ServiceManagement
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

// `--unregister-login-item [--force]` (also via `vaultbar`): remove the login agent and exit. Removing it stops a copy
// launchd is running without the Quit prompt, so every mounted vault is locked first; a busy one is only
// force-locked with --force, otherwise nothing is removed (exit 1). For uninstalling.
if arguments.first == "--unregister-login-item", arguments.count <= 2, arguments.count == 1 || arguments[1] == "--force" {
    // A missing config means no vaults; an unreadable one must not be treated as "nothing to lock".
    let config: Config
    do {
        config = try Config.load() ?? Config.seed
    } catch {
        CommandLineTool.printError("can't read \(Config.url.path): \(error.localizedDescription); nothing changed")
        exit(1)
    }
    guard let mounted = HDIUtil.mountedIfKnown() else {
        CommandLineTool.printError("can't list mounted disk images (hdiutil info failed); nothing changed")
        exit(1)
    }
    let report = UnregisterLock.lockAll(config.vaults, mounted: mounted, force: arguments.count == 2,
                                        detach: HDIUtil.detach)
    for name in report.locked { print("locked \(name)") }
    guard report.mayUnregister else {
        for failure in report.stillUnlocked {
            CommandLineTool.printError("couldn't lock \(failure.vault): \(failure.reason)")
        }
        CommandLineTool.printError("login agent not removed")
        exit(1)
    }
    LoginAgent.remove()
    let old = SMAppService.agent(plistName: Instance.smAppServiceLabel + ".plist")
    if old.status == .enabled || old.status == .requiresApproval { try? old.unregister() }
    print("login agent \(Instance.loginLabel) removed")
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

// One copy at a time, and never zero (see `Succession`). Another copy that is alive (not a terminated pid still
// listed by LaunchServices) or holds the instance lock means this one doesn't start, unless that copy has written a
// fresh hand-off marker naming itself: then this copy acknowledges and waits for it to exit, and takes over.
// The agent copy also retries for 3 s, so a copy that is just exiting doesn't make it give up.
let kind = Instance.isAgentCopy ? "agent" : "non-agent"
let instanceLock = open(Instance.path("lock"), O_CREAT | O_RDWR, 0o600)
func rivalPID() -> Int32? {
    NSRunningApplication.runningApplications(withBundleIdentifier: Instance.bundleID).first {
        $0.processIdentifier != getpid() && !$0.isTerminated && Instance.isAlive($0.processIdentifier)
    }?.processIdentifier
}
let launched = Date()
var predecessor: Int32?
while true {
    let rival = rivalPID()
    if rival == nil, instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) == 0 { break }
    let marker = Instance.read("handoff").flatMap(Succession.parseMarker)
    let waited = Date().timeIntervalSince(launched)
    if let marker, Succession.shouldWait(for: marker, markerPIDAlive: Instance.isAlive(marker.pid), rivalPID: rival, now: Date()) {
        if predecessor != marker.pid {
            predecessor = marker.pid
            Instance.write("handoff-ack", Succession.ackText(successor: getpid(), predecessor: marker.pid))
            log.notice("\(kind, privacy: .public) copy pid \(getpid()): taking over from pid \(marker.pid), waiting for it to exit")
        }
        if waited > Succession.successorWait {
            log.notice("\(kind, privacy: .public) copy pid \(getpid()): pid \(marker.pid) didn't hand over, not starting")
            Instance.remove("handoff-ack")
            exit(0)
        }
    } else if waited >= (Instance.isAgentCopy ? 3 : 0) {
        let reason = rival.map { "another copy is running (pid \($0))" } ?? "the instance lock is held"
        log.notice("not starting (\(kind, privacy: .public) copy, pid \(getpid())): \(reason, privacy: .public)")
        exit(0)
    }
    usleep(100_000)
}
if let predecessor {
    Instance.remove("handoff")
    Instance.remove("handoff-ack")
    log.notice("\(kind, privacy: .public) copy pid \(getpid()) took over from pid \(predecessor)")
}
log.notice("\(kind, privacy: .public) copy started, pid \(getpid())")

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
