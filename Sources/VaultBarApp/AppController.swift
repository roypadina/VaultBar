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
    private var mounted: [String: String] = [:]
    private var statusItem: NSStatusItem?
    private var prompting = false
    private var pendingForce = Set<String>()
    private var pause = AutoLockPause()
    private var screenLocked = false
    private var windows: [String: NSWindow] = [:]

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
            exit(1)
        }
        if let problem = config.validate() {
            alert("VaultBar config is invalid", "\(Config.url.path)\n\n\(problem)")
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        applyLoginItem()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.lockForSleep() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.refresh() }
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
        // Bundled notebook icons; `swift run` has no bundle resources, so it falls back to SF Symbols.
        let image = NSImage(named: paused ? "menubar-paused" : anyUnlocked ? "menubar-unlocked" : "menubar-locked")
            ?? NSImage(systemSymbolName: (anyUnlocked ? "lock.open" : "lock") + (paused ? ".trianglebadge.exclamationmark" : ".fill"),
                       accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "VaultBar: \(state)"
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = paused ? pauseTitle : nil
    }

    private func mountPoint(_ vault: Vault) -> String? { mounted.mountPoint(of: vault) }

    // MARK: Status item + menu

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if let vault = config.vault(named: nil) {
            toggle(vault)
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        refresh()
        let menu = NSMenu()
        for vault in config.vaults {
            let unlocked = mountPoint(vault) != nil
            let header = NSMenuItem(
                title: "\(vault.name)\(vault.name == config.defaultVault ? " (default)" : "") — \(unlocked ? "Unlocked" : "Locked")",
                action: nil, keyEquivalent: "")
            header.image = NSImage(systemSymbolName: unlocked ? "lock.open.fill" : "lock.fill", accessibilityDescription: nil)
            header.isEnabled = false
            menu.addItem(header)
            let action = menuItem(unlocked ? "Lock" : "Unlock…", #selector(menuToggle(_:)))
            action.representedObject = vault.name
            action.indentationLevel = 1
            menu.addItem(action)
        }
        if config.vaults.isEmpty {
            let empty = NSMenuItem(title: "No vaults yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Lock All", #selector(lockAll)))
        menu.addItem(menuItem(pause.isActive() ? pauseTitle : "Pause auto-lock for 1 hour", #selector(togglePause)))
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

    @objc private func menuToggle(_ sender: NSMenuItem) {
        if let vault = config.vault(named: sender.representedObject as? String) { toggle(vault) }
    }

    @objc private func lockAll() {
        refresh()
        for vault in config.vaults { lock(vault, reason: "lock all", onBusy: .ask) }
    }

    // MARK: URL scheme

    private func handle(_ url: URL) {
        guard let (action, name) = VaultURL.parse(url) else {
            alert("Unknown VaultBar link", url.absoluteString)
            return
        }
        guard let vault = config.vault(named: name) else {
            alert(name.isEmpty ? "No default vault is set" : "No vault named \"\(name)\"", "Check VaultBar Settings.")
            return
        }
        refresh()
        switch action {
        case .unlock: if mountPoint(vault) == nil { unlock(vault) }
        case .lock: lock(vault, reason: "link", onBusy: .ask)
        case .toggle: toggle(vault)
        }
    }

    // MARK: Unlock / lock

    private func toggle(_ vault: Vault) {
        refresh()
        if mountPoint(vault) != nil {
            lock(vault, reason: "user", onBusy: .ask)
        } else {
            unlock(vault)
        }
    }

    private func unlock(_ vault: Vault, error: String? = nil) {
        guard !prompting else { return }
        prompting = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Unlock \(vault.name)"
        alert.informativeText = error ?? "Enter the vault password."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock") // Return
        alert.addButton(withTitle: "Cancel") // Esc
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        // The field's String can't be wiped (see Secret); clear it and keep only the byte copy.
        let secret = Secret(field.stringValue)
        field.stringValue = ""
        guard response == .alertFirstButtonReturn, !secret.isEmpty else {
            secret.wipe()
            prompting = false
            return
        }
        let path = vault.expandedPath
        Task {
            let result = await background { HDIUtil.attach(path, secret: secret) }
            secret.wipe()
            prompting = false
            refresh()
            if result.ok {
                log.notice("unlocked \(vault.name, privacy: .public)")
            } else if result.isAuthError {
                unlock(vault, error: "Wrong password. Try again.")
            } else {
                self.alert("Couldn't unlock \(vault.name)", result.output)
            }
        }
    }

    /// Clean detach. Busy: ask (user action) or force after a grace period (auto-lock).
    private func lock(_ vault: Vault, reason: String, onBusy: OnBusy) {
        guard let mountPoint = mountPoint(vault) else { return }
        if case .forceAfter = onBusy, pendingForce.contains(vault.name) { return }
        Task {
            let result = await background { HDIUtil.detach(mountPoint, force: false) }
            refresh()
            if result.ok {
                log.notice("locked \(vault.name, privacy: .public): \(reason, privacy: .public)")
                return
            }
            guard result.isBusy else {
                log.error("lock failed \(vault.name, privacy: .public): \(reason, privacy: .public)")
                if case .ask = onBusy { alert("Couldn't lock \(vault.name)", result.output) }
                return
            }
            switch onBusy {
            case .ask:
                if confirm("Vault busy — force lock?",
                           "\(vault.name) is in use. Unsaved changes in open apps may be lost.", "Force Lock") {
                    await forceLock(vault, mountPoint, reason: reason)
                }
            case .forceAfter(let delay, let trigger):
                pendingForce.insert(vault.name)
                log.notice("\(vault.name, privacy: .public) busy, forcing in \(Int(delay))s: \(reason, privacy: .public)")
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
                if self.mountPoint(vault) != nil { await forceLock(vault, mountPoint, reason: reason) }
            }
        }
    }

    private func forceLock(_ vault: Vault, _ mountPoint: String, reason: String) async {
        let result = await background { HDIUtil.detach(mountPoint, force: true) }
        refresh()
        if result.ok {
            log.notice("force-locked \(vault.name, privacy: .public): \(reason, privacy: .public)")
        } else {
            log.error("force lock failed \(vault.name, privacy: .public): \(reason, privacy: .public)")
        }
    }

    // MARK: Auto-lock

    /// Runs synchronously so the detach finishes before the Mac sleeps.
    private func lockForSleep() {
        guard pause.shouldAutoLock(.sleep, settings: config.autoLock) else { return } // ignores the pause
        refresh()
        for vault in config.vaults {
            guard let mountPoint = mountPoint(vault) else { continue }
            let ok = HDIUtil.detach(mountPoint, force: true).ok
            log.notice("\(ok ? "locked" : "lock failed") \(vault.name, privacy: .public): sleep")
        }
        refresh()
    }

    /// Every 30 s, and when a pause runs out.
    private func tick() {
        if pause.expire() {
            log.notice("auto-lock pause expired")
            refresh()
        }
        checkIdle()
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
            refresh()
            checkIdle()
            return
        }
        pause.start()
        log.notice("auto-lock paused for 1 hour")
        refresh()
        Task {
            try? await Task.sleep(for: .seconds(AutoLockPause.duration))
            tick() // ends the pause on time; a no-op if it was resumed (or restarted and not yet due)
        }
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
            if announce { alert("Raycast scripts updated", "\(config.vaults.count * 2) scripts in \(directory.path)") }
        } catch {
            log.error("raycast scripts: \(error.localizedDescription, privacy: .public)")
            if announce { alert("Couldn't write Raycast scripts", error.localizedDescription) }
        }
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if config.launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
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

/// Runs blocking hdiutil/diskutil work off the main thread.
private func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(operation: work).value
}
