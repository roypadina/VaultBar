import AppKit
import OSLog
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import VaultBarCore

/// Lock events only: vault name + reason. Never a password.
let log = Logger(subsystem: "com.padina.vaultbar", category: "lock")

enum OnBusy {
    case ask
    case forceAfter(TimeInterval, AutoLockTrigger)
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var config = Config.seed
    private var mounted: [String: Mount] = [:]
    /// Lock / unlock events for the menu's "Last:" line and the History window. Memory only.
    @Published private(set) var history = EventLog()
    private var statusItem: NSStatusItem?
    private var prompting = false
    private var pendingForce = Set<String>()
    private var pause = AutoLockPause()
    private var screenLocked = false
    /// attach / detach / create calls still running (see `background`)
    private var inFlight = 0
    /// Vaults whose private mount folder was just created for an unlock that hasn't finished.
    private var attaching = Set<String>()
    private var windows: [String: NSWindow] = [:]
    private lazy var passwordPanel = PasswordPanel()

    /// This copy was started by the login agent (see `LoginAgent`).
    private let isAgentInstance = Instance.isAgentCopy
    /// The login agent's launchd job is loaded (checked after `applyLoginItem`).
    private var loginAgentLoaded = false
    /// A hand-off or update takeover in progress (see `Succession`); this copy keeps running until it completes.
    private var succession: Task<Void, Never>?
    private var nextSuccessionAttempt = Date.distantPast
    /// Installing or removing the login agent; no hand-off until it's done.
    private var registering = false

    override init() { super.init() }

    /// For rendering views with demo data (see `--render-settings`); never saved.
    init(preview: Config) {
        super.init()
        config = preview
    }

    // MARK: Launch

    /// Config loads here, before any vaultbar:// URL that launched the app is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            if let loaded = try Config.load() {
                config = loaded
            } else {
                try config.save()
            }
        } catch {
            alert("VaultBar can't read its config", "\(Config.url.path)\n\n\(error.localizedDescription)\n\nFix or delete the file, then reopen VaultBar.")
            exit(0) // not 1: the LaunchAgent would restart straight into the same alert
        }
        if let problem = config.validate() {
            alert("VaultBar config is invalid", "\(Config.url.path)\n\n\(problem)")
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        if !Instance.isHeadless {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        let loginItem = applyLoginItem()
        Task {
            await loginItem.value
            try? await Task.sleep(for: .seconds(2))
            handOffIfIdle()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.lockForSleep() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            // Covers mounts and ejects from anywhere (Terminal hdiutil, Finder Eject); once more a second later
            // in case hdiutil info lags the notification.
            // An eject outside VaultBar leaves the private mount folder behind: remove it here too.
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.refresh()
                    self.removeStaleMountFolders()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        self.refresh()
                        self.removeStaleMountFolders()
                    }
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.screenLocked = true
                if self.pause.shouldAutoLock(.screenLock, settings: self.config.autoLock) {
                    self.autoLock(.screenLock, reason: "screen lock", forceAfter: 30)
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.screenLocked = false }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        refresh()
        removeStaleMountFolders() // a crash or force quit can leave one behind
        setUpNotifications()
        applyPanicHotkey()
        syncScripts() // idempotent; brings scripts added in an update without pressing Regenerate
    }

    // MARK: Succession (always one copy running)

    /// Started by Finder, `open` or a link while the login agent is enabled: once idle, let launchd run the
    /// supervised copy instead (it restarts after a crash). A `vaultbar://` action that launched this copy finishes
    /// here first. This copy exits only after the agent copy has acknowledged and is alive; if launchd doesn't
    /// start it within 20 s, this copy stays and tries again later.
    private func handOffIfIdle() {
        guard succession == nil, !registering, Date() >= nextSuccessionAttempt,
              canHandOff(isAgent: isAgentInstance, handOffDisabled: CommandLine.arguments.contains("--no-handoff"),
                         launchAtLogin: config.launchAtLogin, agentEnabled: loginAgentLoaded,
                         activity: activity) else { return }
        succession = Task {
            let service = LoginAgent.service
            _ = await handOver(timeout: Succession.handOffTimeout, what: "hand-off to the login agent") { elapsed, done in
                if let at = Succession.handOffKickstarts.first(where: { $0 <= elapsed && !done.contains($0) }) {
                    let result = await self.run("/bin/launchctl", ["kickstart", service])
                    log.notice("hand-off: launchctl kickstart \(service, privacy: .public) (exit \(result.status))")
                    return at
                }
                return nil
            }
            succession = nil
        }
    }

    /// The version this process runs, read at launch; nil without a bundle (`swift run`).
    private let runningVersion = AppController.version(of: Bundle.main.bundleURL)

    private static func version(of bundle: URL) -> String? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return "\(short) (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// An upgrade (brew) replaced the bundle under this process: once idle, start the new copy and exit only after
    /// it has acknowledged and is alive (it then refreshes the login agent and hands off). While the bundle can't
    /// be read (mid-move), keep running and check again on the next tick.
    private func relaunchIfUpdated() {
        guard succession == nil, let runningVersion, Date() >= nextSuccessionAttempt else { return }
        let onDisk = Self.version(of: Bundle.main.bundleURL)
        guard shouldRelaunchForUpdate(running: runningVersion, onDisk: onDisk, activity: activity), let onDisk else { return }
        log.notice("update detected \(runningVersion, privacy: .public) → \(onDisk, privacy: .public)")
        let bundle = Bundle.main.bundlePath
        succession = Task {
            _ = await handOver(timeout: Succession.updateTimeout, what: "update to \(onDisk)") { _, done in
                guard done.isEmpty else { return nil }
                let result = await self.run("/usr/bin/open", ["-n", bundle])
                log.notice("update: started the new copy (open exit \(result.status))")
                return 0
            }
            succession = nil
        }
    }

    /// The predecessor side of `Succession`: write the marker, `start` the successor (called every 200 ms with the
    /// elapsed time and the start times already used; returns the time it used, if any), and exit 0 as soon as the
    /// successor has acknowledged and is alive and nothing is in progress here. Returns false after `timeout`.
    private func handOver(timeout: TimeInterval, what: String,
                          start: (TimeInterval, Set<TimeInterval>) async -> TimeInterval?) async -> Bool {
        let began = Date()
        Instance.remove("handoff-ack")
        Instance.write("handoff", Succession.markerText(pid: getpid(), date: began))
        var started = Set<TimeInterval>()
        while Date().timeIntervalSince(began) < timeout {
            if let used = await start(Date().timeIntervalSince(began), started) { started.insert(used) }
            let ack = Instance.read("handoff-ack").flatMap(Succession.parseAck)
            if let ack, Succession.mayExit(ack: ack, myPID: getpid(), successorAlive: Instance.isAlive(ack.successor),
                                           activity: activity) {
                log.notice("\(what, privacy: .public): pid \(ack.successor) is taking over, exiting")
                exit(0)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        Instance.remove("handoff")
        Instance.remove("handoff-ack")
        nextSuccessionAttempt = Date().addingTimeInterval(120)
        log.error("\(what, privacy: .public): no successor within \(Int(timeout)) s; staying, will retry in 2 min")
        return false
    }

    private var activity: Activity {
        Activity(prompting: prompting, inFlight: inFlight, pendingForce: pendingForce.count, paused: pause.isActive(),
                 uiOpen: NSApp.modalWindow != nil || statusItem?.menu != nil || windows.values.contains(where: \.isVisible))
    }

    /// A tool run off the main thread that, unlike `background`, doesn't count as work in progress.
    private func run(_ path: String, _ args: [String]) async -> ToolResult {
        await Task.detached { Tool.run(path, args) }.value
    }

    /// Quitting with a vault unlocked leaves it unguarded, so ask. Logout/restart/shutdown carry a quit reason
    /// (macOS unmounts everything then anyway) and go through without asking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        refresh()
        let unlocked = config.vaults.filter { mountPoint($0) != nil }
        guard !unlocked.isEmpty else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Quit VaultBar?"
        alert.informativeText = "Auto-lock stops while VaultBar is closed.\n\nUnlocked: \(unlocked.map(\.name).joined(separator: ", "))"
        alert.addButton(withTitle: "Lock All & Quit")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel") // Esc
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for vault in unlocked {
                guard let mountPoint = mountPoint(vault) else { continue }
                var result = HDIUtil.detach(mountPoint, force: false)
                if result.isBusy, confirm("Vault busy — force lock?",
                                          "\(vault.name) is in use. Unsaved changes in open apps may be lost.", "Force Lock") {
                    result = HDIUtil.detach(mountPoint, force: true)
                }
                guard result.ok else { // still unlocked: stay running so auto-lock keeps guarding it
                    refresh()
                    return .terminateCancel
                }
                locked(vault, at: mountPoint, reason: "quit", forced: false)
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Turned off while running as the agent copy: removing it earlier would have stopped this process.
        if !config.launchAtLogin, isAgentInstance { LoginAgent.remove() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { self.handle(url) }
        }
    }

    // MARK: State

    func refresh() {
        mounted = HDIUtil.mounted()
        let anyUnlocked = config.vaults.contains { mountPoint($0) != nil }
        let paused = pause.isActive()
        let state = (anyUnlocked ? "a vault is unlocked" : "vaults locked") + (paused ? ", auto-lock paused" : "")
        let image = statusImage(badge: paused ? "menubar-paused" : anyUnlocked ? "menubar-unlocked" : nil)
            // `swift run` has no bundle resources
            ?? NSImage(systemSymbolName: (anyUnlocked ? "lock.open" : "lock") + (paused ? ".trianglebadge.exclamationmark" : ".fill"),
                       accessibilityDescription: nil)
        image?.accessibilityDescription = "VaultBar: \(state)"
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = paused ? pauseTitle : nil
    }

    private func mountPoint(_ vault: Vault) -> String? { mounted.mountPoint(of: vault) }

    /// A locked vault must not have a private mount folder (`rmdir`: only empty ones go).
    private func removeStaleMountFolders() {
        for folder in MountFolder.stale(vaults: config.vaults, mounted: mounted, attaching: attaching) {
            MountFolder.remove(folder)
        }
    }

    /// Locked: the template notebook. Unlocked / paused: the notebook in the menu bar's text colour plus a colour
    /// badge (amber open padlock / orange warning), so an open vault stands out.
    private func statusImage(badge: String?) -> NSImage? {
        guard let badge else {
            let locked = NSImage(named: "menubar-locked")
            locked?.isTemplate = true
            return locked
        }
        guard let notebook = NSImage(named: "menubar-notebook"), let color = NSImage(named: badge) else { return nil }
        let image = NSImage(size: notebook.size, flipped: false) { rect in
            notebook.draw(in: rect)
            NSColor.labelColor.set() // resolved for the menu bar's current appearance at draw time
            rect.fill(using: .sourceAtop)
            color.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Status item + menu

    @objc private func statusItemClicked() {
        // Control-click must open the menu like a right-click. Use the live modifier state as well as the event's:
        // the status button's mouse-up doesn't reliably carry the Control flag.
        let event = NSApp.currentEvent
        let flags = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        let right = event?.type == .rightMouseUp || event?.type == .rightMouseDown || (event?.buttonNumber ?? 0) == 1
        let defaultVault = config.vault(named: nil)
        switch StatusClick.action(rightButton: right, control: flags.contains(.control), option: flags.contains(.option),
                                  hasDefault: defaultVault != nil) {
        case .menu: showMenu()
        case .lockAll: lockAll() // ⌥-click: clean, asks before forcing
        case .toggleDefault: if let defaultVault { perform(.toggle, on: defaultVault, reason: "user") }
        }
    }

    private func showMenu() {
        refresh()
        let menu = NSMenu()
        for vault in config.vaults {
            let mount = mounted.mount(of: vault)
            let state = mount.map { $0.readOnly ? "Unlocked (read-only)" : "Unlocked" } ?? "Locked"
            let header = NSMenuItem(
                title: "\(vault.name)\(vault.name == config.defaultVault ? " (default)" : "") — \(state)",
                action: nil, keyEquivalent: "")
            header.image = NSImage(systemSymbolName: mount != nil ? "lock.open.fill" : "lock.fill", accessibilityDescription: nil)
            header.isEnabled = false
            menu.addItem(header)
            if mount != nil {
                menu.addItem(command("Lock", .lock, vault))
                menu.addItem(command("Open in Finder", .open, vault))
            } else {
                // ⌥ swaps "Unlock…" for the other mode.
                menu.addItem(command(vault.isReadOnly ? "Unlock Read-Only…" : "Unlock…", .unlock, vault))
                menu.addItem(command(vault.isReadOnly ? "Unlock Read-Write…" : "Unlock Read-Only…", .unlock, vault,
                                     readOnly: !vault.isReadOnly, alternate: true))
                menu.addItem(command("Unlock & Open…", .open, vault))
            }
        }
        if config.vaults.isEmpty {
            let empty = NSMenuItem(title: "No vaults yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Lock All", #selector(lockAll)))
        menu.addItem(menuItem(pause.isActive() ? pauseTitle : "Pause auto-lock for 1 hour", #selector(togglePause)))
        if let last = history.last {
            let item = NSMenuItem(title: "Last: \(last.text), \(last.date.formatted(date: .omitted, time: .shortened))",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(menuItem("History…", #selector(showHistory)))
        menu.addItem(.separator())
        menu.addItem(menuItem("New Vault…", #selector(newVault)))
        menu.addItem(menuItem("Add Existing Vault…", #selector(addExisting)))
        menu.addItem(menuItem("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("About VaultBar", #selector(showAbout)))
        menu.addItem(menuItem("Support on Ko-fi ☕", #selector(openKoFi)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit VaultBar", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        // Attach the menu only for this click, so a left-click keeps toggling the default vault.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func command(_ title: String, _ action: VaultAction, _ vault: Vault, readOnly: Bool? = nil,
                         alternate: Bool = false) -> NSMenuItem {
        let item = menuItem(title, #selector(menuPerform(_:)))
        item.representedObject = VaultRequest(action: action, name: vault.name, readOnly: readOnly)
        item.indentationLevel = 1
        item.keyEquivalentModifierMask = alternate ? .option : []
        item.isAlternate = alternate
        return item
    }

    @objc private func menuPerform(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? VaultRequest, let vault = config.vault(named: request.name) else { return }
        perform(request.action, on: vault, reason: "user", readOnly: request.readOnly)
    }

    @objc private func lockAll() {
        refresh()
        for vault in config.vaults { lock(vault, reason: "lock all", onBusy: .ask) }
    }

    /// Global hotkey: lock every vault now; busy ones are forced unless "Panic hotkey forces" is off.
    func panicLock() {
        guard config.panicForces else { return lockAll() }
        refresh()
        for vault in config.vaults {
            guard let mountPoint = mountPoint(vault) else { continue }
            Task {
                let result = await background { HDIUtil.detach(mountPoint, force: true) }
                refresh()
                if result.ok { locked(vault, at: mountPoint, reason: "panic hotkey", forced: true) }
                else { lockFailed(vault, reason: "panic hotkey", notify: true) }
            }
        }
    }

    // MARK: URL scheme

    private func handle(_ url: URL) {
        guard let request = VaultURL.parse(url) else {
            alert("Unknown VaultBar link", url.absoluteString)
            return
        }
        if request.action == .lockAll { return lockAll() }
        guard let vault = config.vault(named: request.name) else {
            alert(request.name.isEmpty ? "No default vault is set" : "No vault named \"\(request.name)\"", "Check VaultBar Settings.")
            return
        }
        perform(request.action, on: vault, reason: "link", readOnly: request.readOnly)
    }

    // MARK: Unlock / lock / open

    /// `readOnly`: a one-off choice (⌥ menu item, `?readonly=`); nil uses the vault's own setting.
    private func perform(_ action: VaultAction, on vault: Vault, reason: String, readOnly: Bool? = nil) {
        refresh()
        switch action.step(unlocked: mountPoint(vault) != nil, openAfterUnlock: config.openAfterUnlock) {
        case .nothing: break
        case .lock: lock(vault, reason: reason, onBusy: .ask)
        case .openInFinder: openInFinder(vault)
        case .promptUnlock(let thenOpen): unlock(vault, thenOpen: thenOpen, readOnly: readOnly ?? vault.isReadOnly)
        }
    }

    private func openInFinder(_ vault: Vault) {
        if let mountPoint = mountPoint(vault) { NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint)) }
    }

    private func unlock(_ vault: Vault, thenOpen: Bool, readOnly: Bool, error: String? = nil) {
        guard !prompting else {
            if passwordPanel.isVisible { passwordPanel.makeKeyAndOrderFront(nil) } // asked twice: bring it back
            return
        }
        prompting = true
        // Default run-loop mode: runs after a status menu has finished closing, so it can't take focus back.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                self.passwordPanel.ask(vault: vault.name, readOnly: readOnly,
                                       message: error ?? "Enter the vault password.") { secret, chosenReadOnly in
                    self.attach(vault, secret, thenOpen: thenOpen, readOnly: chosenReadOnly) // a retry keeps it
                }
            }
        }
    }

    private func attach(_ vault: Vault, _ secret: Secret?, thenOpen: Bool, readOnly: Bool) {
        guard let secret, !secret.isEmpty else {
            secret?.wipe()
            prompting = false
            return
        }
        // A private mount folder exists only while the vault is unlocked: created here, removed after lock.
        let folder = vault.expandedMountPoint
        attaching.insert(vault.name)
        if let folder, let problem = MountFolder.prepare(folder) {
            attaching.remove(vault.name)
            secret.wipe()
            prompting = false
            alert("Couldn't unlock \(vault.name)", problem)
            return
        }
        let path = vault.expandedPath, hidden = vault.isHidden
        Task {
            let result = await background {
                HDIUtil.attach(path, mountPoint: folder, hidden: hidden, readOnly: readOnly, secret: secret)
            }
            secret.wipe()
            prompting = false
            attaching.remove(vault.name)
            refresh()
            if result.ok {
                log.notice("unlocked \(vault.name, privacy: .public)\(readOnly ? " read-only" : "", privacy: .public)")
                record("Unlocked \(vault.name)\(readOnly ? " (read-only)" : "")")
                if thenOpen { openInFinder(vault) }
                return
            }
            if let folder { MountFolder.remove(folder) }
            if result.isAuthError {
                unlock(vault, thenOpen: thenOpen, readOnly: readOnly, error: "Wrong password. Try again.")
            } else {
                self.alert("Couldn't unlock \(vault.name)", result.output)
            }
        }
    }

    /// After every successful detach: remove the private mount folder (the one it was actually mounted on, in case
    /// the setting changed while unlocked) and record it.
    private func locked(_ vault: Vault, at mountPoint: String, reason: String, forced: Bool, notify: Bool = false) {
        if !mountPoint.hasPrefix("/Volumes/") { MountFolder.remove(mountPoint) }
        if let folder = vault.expandedMountPoint { MountFolder.remove(folder) }
        log.notice("\(forced ? "force-locked" : "locked", privacy: .public) \(vault.name, privacy: .public): \(reason, privacy: .public)")
        record("\(forced ? "Force-locked" : "Locked") \(vault.name) (\(reason))")
        if notify { self.notify("A vault was locked (\(reason)).") }
    }

    private func lockFailed(_ vault: Vault, reason: String, notify: Bool) {
        log.error("lock failed \(vault.name, privacy: .public): \(reason, privacy: .public)")
        record("Couldn't lock \(vault.name) (\(reason))")
        if notify { self.notify("Couldn't lock a vault. It is still unlocked.") }
    }

    func record(_ text: String) { history.add(text) }

    /// Clean detach. Busy: ask (user action) or force after a grace period (auto-lock).
    private func lock(_ vault: Vault, reason: String, onBusy: OnBusy) {
        guard let mountPoint = mountPoint(vault) else { return }
        if case .forceAfter = onBusy, pendingForce.contains(vault.name) { return }
        Task {
            let result = await background { HDIUtil.detach(mountPoint, force: false) }
            refresh()
            let automatic = if case .forceAfter = onBusy { true } else { false }
            if result.ok {
                locked(vault, at: mountPoint, reason: reason, forced: false, notify: automatic)
                return
            }
            guard result.isBusy else {
                lockFailed(vault, reason: reason, notify: automatic)
                if !automatic { alert("Couldn't lock \(vault.name)", result.output) }
                return
            }
            switch onBusy {
            case .ask:
                if confirm("Vault busy — force lock?",
                           "\(vault.name) is in use. Unsaved changes in open apps may be lost.", "Force Lock") {
                    await forceLock(vault, mountPoint, reason: reason, notify: false)
                }
            case .forceAfter(let delay, let trigger):
                pendingForce.insert(vault.name)
                log.notice("\(vault.name, privacy: .public) busy, forcing in \(Int(delay))s: \(reason, privacy: .public)")
                record("\(vault.name) is in use, force-locking in \(Int(delay)) s (\(reason))")
                if trigger == .idle { // the user may be right there, watching rather than typing
                    notify("Force-locking a vault in \(Int(delay)) s. It is still in use.", keepUnlockedAction: true)
                }
                try? await Task.sleep(for: .seconds(delay))
                pendingForce.remove(vault.name)
                if pause.isActive() {
                    log.notice("force lock skipped, auto-lock paused: \(vault.name, privacy: .public)")
                    return
                }
                guard trigger.shouldForce(screenLocked: screenLocked, idleSeconds: idleSeconds(),
                                          idleMinutes: config.autoLock.idleMinutes, paused: false) else {
                    log.notice("force lock cancelled, user returned: \(vault.name, privacy: .public)")
                    return
                }
                refresh()
                if self.mountPoint(vault) != nil { await forceLock(vault, mountPoint, reason: reason, notify: true) }
            }
        }
    }

    private func forceLock(_ vault: Vault, _ mountPoint: String, reason: String, notify: Bool) async {
        let result = await background { HDIUtil.detach(mountPoint, force: true) }
        refresh()
        if result.ok {
            locked(vault, at: mountPoint, reason: reason, forced: true, notify: notify)
        } else {
            lockFailed(vault, reason: reason, notify: true)
        }
    }

    // MARK: Auto-lock

    /// Runs synchronously so the detach finishes before the Mac sleeps.
    private func lockForSleep() {
        guard pause.shouldAutoLock(.sleep, settings: config.autoLock) else { return } // ignores the pause
        refresh()
        for vault in config.vaults {
            guard let mountPoint = mountPoint(vault) else { continue }
            if HDIUtil.detach(mountPoint, force: true).ok {
                locked(vault, at: mountPoint, reason: "sleep", forced: true)
            } else {
                lockFailed(vault, reason: "sleep", notify: true)
            }
        }
        refresh()
    }

    /// Every 30 s, and when a pause runs out.
    private func tick() {
        if pause.expire() {
            log.notice("auto-lock pause expired")
            record("Auto-lock pause ended")
            refresh()
        }
        refresh()
        removeStaleMountFolders() // backstop for an eject the notifications missed
        checkIdle()
        relaunchIfUpdated()
        handOffIfIdle()
    }

    private func checkIdle() {
        if pause.shouldAutoLock(.idle, settings: config.autoLock, idleSeconds: idleSeconds()) {
            autoLock(.idle, reason: "idle \(config.autoLock.idleMinutes) min", forceAfter: 60)
        }
    }

    /// Keyboard/mouse only, so a local agent working in a vault doesn't count as activity.
    private func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var pauseTitle: String {
        "Auto-lock paused until \(pause.until?.formatted(date: .omitted, time: .shortened) ?? "") — Resume"
    }

    @objc private func togglePause() {
        if pause.isActive() {
            pause.resume()
            log.notice("auto-lock resumed")
            record("Auto-lock resumed")
            refresh()
            checkIdle()
            return
        }
        pauseAutoLock(minutes: 60)
    }

    func pauseAutoLock(minutes: Int) {
        pause.start(duration: TimeInterval(minutes * 60))
        log.notice("auto-lock paused for \(minutes) min")
        record("Auto-lock paused for \(minutes) min")
        refresh()
        Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            tick() // ends the pause on time; a no-op if it was resumed (or restarted and not yet due)
        }
    }

    /// The pre-force notification's "Keep unlocked 15 min"; never shortens a longer pause.
    func keepUnlocked() {
        if let until = pause.until, pause.isActive(), until > Date().addingTimeInterval(15 * 60) { return }
        pauseAutoLock(minutes: 15)
    }

    private func autoLock(_ trigger: AutoLockTrigger, reason: String, forceAfter delay: TimeInterval) {
        refresh()
        for vault in config.vaults { lock(vault, reason: reason, onBusy: .forceAfter(delay, trigger)) }
    }

    // MARK: Config

    /// Validates, saves, and regenerates Raycast scripts when the vault list changed. Returns the problem, if any.
    @discardableResult
    func update(_ change: (inout Config) -> Void) -> String? {
        var next = config
        change(&next)
        if let problem = next.validate() {
            alert("Can't save that", problem)
            return problem
        }
        do {
            try next.save()
        } catch {
            alert("Couldn't save \(Config.url.path)", error.localizedDescription)
            return error.localizedDescription
        }
        let old = config
        config = next
        if old.raycastScriptsDir != next.raycastScriptsDir, let oldDirectory = old.raycastDirectory {
            try? Raycast.sync([], in: oldDirectory) // removes only the scripts VaultBar wrote there
        }
        if old.vaults != next.vaults || old.raycastScriptsDir != next.raycastScriptsDir { syncScripts() }
        if old.launchAtLogin != next.launchAtLogin { applyLoginItem() }
        if old.panicHotkey != next.panicHotkey { applyPanicHotkey() }
        refresh()
        return nil
    }

    func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func syncScripts(announce: Bool = false) {
        guard let directory = config.raycastDirectory else { return }
        do {
            try Raycast.sync(config.vaults, in: directory)
            if announce { alert("Raycast scripts updated", "\(config.vaults.count * 3) scripts in \(directory.path)") }
        } catch {
            log.error("raycast scripts: \(error.localizedDescription, privacy: .public)")
            if announce { alert("Couldn't write Raycast scripts", error.localizedDescription) }
        }
    }

    /// Launch and the Settings toggle: install (or remove) the login agent, and retire the login items of older
    /// versions. The agent copy never reloads its own job; turning it off there takes effect at quit.
    @discardableResult
    private func applyLoginItem() -> Task<Void, Never> {
        // 0.1.0 used a plain login item; keeping it too would start two copies at login.
        if SMAppService.mainApp.status == .enabled {
            do { try SMAppService.mainApp.unregister() } catch {
                log.error("old login item: \(error.localizedDescription, privacy: .public)")
            }
        }
        let on = config.launchAtLogin, isAgent = isAgentInstance, executable = Bundle.main.executablePath ?? ""
        registering = true
        return Task {
            let problem = await Task.detached { () -> String? in
                if on { return isAgent ? nil : LoginAgent.install(executable: executable) }
                if !isAgent { LoginAgent.remove() }
                return nil
            }.value
            await LoginAgent.removeSMAppServiceAgent()
            loginAgentLoaded = await Task.detached { LoginAgent.isLoaded }.value
            if let problem {
                log.error("login agent: \(problem, privacy: .public)")
            } else {
                let what = !on ? "removed" : isAgent ? "running this copy" : "installed"
                log.notice("login agent \(what, privacy: .public) (loaded: \(self.loginAgentLoaded))")
            }
            registering = false
        }
    }

    func rename(_ vault: Vault, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard name != vault.name else { return true }
        return update { config in
            if let index = config.vaults.firstIndex(of: vault) { config.vaults[index].name = name }
            if config.defaultVault == vault.name { config.defaultVault = name }
        } == nil
    }

    /// Only the config entry goes; the image file is never touched.
    func remove(_ vault: Vault) {
        update { config in
            config.vaults.removeAll { $0 == vault }
            if config.defaultVault == vault.name { config.defaultVault = config.vaults.first?.name }
        }
    }

    @discardableResult
    private func add(_ vault: Vault) -> String? {
        update { config in
            config.vaults.append(vault)
            if config.defaultVault == nil { config.defaultVault = vault.name }
        }
    }

    // MARK: Add / create

    @objc func addExisting() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = "Choose an encrypted .sparsebundle or .dmg"
        panel.allowedContentTypes = ["sparsebundle", "dmg"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if config.vaults.contains(where: { HDIUtil.resolve($0.imagePath) == HDIUtil.resolve(url.path) }) {
            alert("Already in VaultBar", url.path)
            return
        }
        guard HDIUtil.isEncrypted(url.path) else {
            alert("Not an encrypted disk image", "\(url.lastPathComponent) isn't encrypted, so VaultBar won't manage it.")
            return
        }
        let base = url.deletingPathExtension().lastPathComponent
        var name = base
        var n = 2
        while config.vaults.contains(where: { Raycast.slug($0.name) == Raycast.slug(name) }) {
            name = "\(base) \(n)"
            n += 1
        }
        add(Vault(name: name, imagePath: NSString(string: url.path).abbreviatingWithTildeInPath))
    }

    /// Returns an error message, or nil on success.
    func createVault(name: String, volumeName: String, folder: URL, sizeGB: Int, secret: Secret) async -> String? {
        defer { secret.wipe() }
        let path = folder.appendingPathComponent("\(volumeName).sparsebundle").path
        if FileManager.default.fileExists(atPath: path) { return "\(path) already exists." }
        let result = await background {
            HDIUtil.create(imagePath: path, volumeName: volumeName, sizeGB: sizeGB, secret: secret)
        }
        guard result.ok else { return result.output.isEmpty ? "diskutil failed (\(result.status))" : result.output }
        if let problem = add(Vault(name: name, imagePath: NSString(string: path).abbreviatingWithTildeInPath)) {
            return problem
        }
        let command = "sudo mdutil -i off \"/Volumes/\(volumeName)\""
        if confirm("\(name) created",
                   "Stop Spotlight indexing it once: unlock the vault, then run in Terminal:\n\n\(command)",
                   "Copy Command", cancel: "Done") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        return nil
    }

    func chooseRaycastFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Folder for VaultBar's Raycast Script Commands (your Raycast script directory)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.raycastScriptsDir = NSString(string: url.path).abbreviatingWithTildeInPath }
    }

    // MARK: Windows

    @objc private func showAbout() {
        showWindow("about", "About VaultBar", AboutView())
    }

    @objc private func openKoFi() {
        NSWorkspace.shared.open(AboutView.koFi)
    }

    @objc private func showHistory() {
        showWindow("history", "VaultBar History", HistoryView(controller: self))
    }

    func showChangePassword(_ vault: Vault) {
        refresh()
        guard mountPoint(vault) == nil else { return alert("Lock \(vault.name) first", "The password can only be changed while the vault is locked.") }
        showWindow("password", "Change Password — \(vault.name)",
                   ChangePasswordView(controller: self, vault: vault) { [weak self] in self?.windows["password"]?.close() })
    }

    /// `diskutil image chpass`, then proves the new password opens the image (read-only, hidden, at a temporary
    /// private folder, locked again at once). Returns an error message, or nil on success.
    func changePassword(_ vault: Vault, old: Secret, new: Secret) async -> String? {
        defer { old.wipe(); new.wipe() }
        refresh()
        guard mountPoint(vault) == nil else { return "Lock \(vault.name) first." }
        let path = vault.expandedPath
        let result = await background { HDIUtil.changePassword(path, old: old, new: new) }
        guard result.ok else {
            return "The password wasn't changed. Check the current password.\n\n\(result.output)"
        }
        let folder = NSTemporaryDirectory() + "vaultbar-check-\(UUID().uuidString)"
        if let problem = MountFolder.prepare(folder) { return "The password was changed, but couldn't be checked: \(problem)" }
        let check = await background { HDIUtil.attach(path, mountPoint: folder, hidden: true, readOnly: true, secret: new) }
        if check.ok { _ = await background { HDIUtil.detach(folder, force: true) } }
        MountFolder.remove(folder)
        refresh()
        guard check.ok else {
            return "diskutil reported success, but the new password doesn't open \(vault.name). Try the old one.\n\n\(check.output)"
        }
        log.notice("password changed: \(vault.name, privacy: .public)")
        record("Changed the password of \(vault.name)")
        return nil
    }

    /// Settings: a binding to one vault's field, saved through `update`.
    func binding<T>(_ vault: Vault, _ keyPath: WritableKeyPath<Vault, T>) -> Binding<T> {
        Binding(get: { self.config.vaults.first { $0.name == vault.name }?[keyPath: keyPath] ?? vault[keyPath: keyPath] },
                set: { value in self.update { config in
                    if let index = config.vaults.firstIndex(where: { $0.name == vault.name }) { config.vaults[index][keyPath: keyPath] = value }
                } })
    }

    func chooseMountFolder(_ vault: Vault) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where \(vault.name)'s private mount folder goes. VaultBar mounts it at <this folder>/\(vault.name), creating it on unlock and removing it on lock."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = NSString(string: url.appendingPathComponent(vault.name).path).abbreviatingWithTildeInPath
        update { config in
            if let index = config.vaults.firstIndex(where: { $0.name == vault.name }) { config.vaults[index].mountPoint = folder }
        }
    }

    @objc func showSettings() {
        showWindow("settings", "VaultBar Settings", SettingsView(controller: self))
    }

    @objc func newVault() {
        showWindow("new", "New Vault", NewVaultView(controller: self) { [weak self] in self?.windows["new"]?.close() })
    }

    private func showWindow(_ id: String, _ title: String, _ view: some View) {
        NSApp.activate()
        if let window = windows[id], window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable] // fit to content
        window.isReleasedWhenClosed = false
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// An accessory app has no menu bar, but key equivalents still route through mainMenu: this makes ⌘V etc. work.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem()) // app menu slot
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Alerts

    func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    func confirm(_ title: String, _ text: String, _ ok: String, cancel: String = "Cancel") -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension AppController {
    /// Runs blocking hdiutil/diskutil work off the main thread, counted in `inFlight` so a hand-off waits for it.
    func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        inFlight += 1
        defer { inFlight -= 1 }
        return await Task.detached(operation: work).value
    }
}
