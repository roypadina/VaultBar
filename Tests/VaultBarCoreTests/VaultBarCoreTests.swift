import Foundation
import Testing
@testable import VaultBarCore

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vaultbar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let sample = Config(
    defaultVault: "MyVault",
    autoLock: AutoLock(onSleep: true, onScreenLock: true, idleMinutes: 15),
    launchAtLogin: true,
    vaults: [Vault(name: "MyVault", imagePath: "/Users/alice/Vaults/MyVault.sparsebundle")],
    raycastScriptsDir: "~/Scripts/Raycast"
)

@Suite("VaultBar core")
struct VaultBarCoreTests {
    @Test("config round-trips with mode 600, missing file is first run, bad JSON throws")
    func configFile() throws {
        let url = try tempDir().appendingPathComponent("sub/vaults.json")
        #expect(try Config.load(from: url) == nil)
        try sample.save(to: url)
        #expect(try Config.load(from: url) == sample)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try Data("{".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Config.load(from: url) }
    }

    @Test("first-run seed is empty; a config without raycastScriptsDir still loads")
    func seedAndOlderConfig() throws {
        #expect(Config.seed.vaults.isEmpty && Config.seed.defaultVault == nil && Config.seed.raycastScriptsDir == nil)
        #expect(Config.seed.validate() == nil)
        let url = try tempDir().appendingPathComponent("vaults.json")
        try Data("""
            {"defaultVault": "MyVault", "launchAtLogin": true,
             "autoLock": {"onSleep": true, "onScreenLock": false, "idleMinutes": 5},
             "vaults": [{"name": "MyVault", "imagePath": "~/Vaults/MyVault.sparsebundle"}]}
            """.utf8).write(to: url)
        let config = try #require(try Config.load(from: url))
        #expect(config.raycastScriptsDir == nil && config.raycastDirectory == nil && !config.openAfterUnlock)
        #expect(config.vault(named: "")?.imagePath == "~/Vaults/MyVault.sparsebundle")
        #expect(sample.raycastDirectory?.path == NSString(string: "~/Scripts/Raycast").expandingTildeInPath)
    }

    @Test("validation and default-vault lookup")
    func validation() {
        var config = sample
        #expect(config.validate() == nil)
        #expect(config.vault(named: "")?.name == "MyVault")
        #expect(config.vault(named: nil)?.name == "MyVault")
        #expect(config.vault(named: "Nope") == nil)
        config.vaults.append(Vault(name: "my vault", imagePath: "/a"))
        config.vaults.append(Vault(name: "My-Vault", imagePath: "/b"))
        #expect(config.validate() != nil) // same slug
        config = sample
        config.defaultVault = "Missing"
        #expect(config.validate() != nil)
        config.defaultVault = nil
        #expect(config.vault(named: "") == nil)
        config.vaults[0].name = " "
        #expect(config.validate() != nil)
        config.vaults[0].name = "a\nb"
        #expect(config.validate() != nil)
    }

    @Test("hdiutil info parsing matches by resolved image path")
    func parseInfo() throws {
        let dir = try tempDir()
        let image = dir.appendingPathComponent("V.sparsebundle")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link.sparsebundle")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let plist: [String: Any] = ["images": [
            ["image-path": "/System/x.dmg", "system-entities": [["dev-entry": "/dev/disk6"]]],
            ["image-path": image.path, "system-entities": [
                ["dev-entry": "/dev/disk8"],
                ["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/MyVault 1"],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let mounted = HDIUtil.parseInfo(data)
        #expect(mounted.count == 1)
        #expect(mounted.mountPoint(of: Vault(name: "V", imagePath: link.path)) == "/Volumes/MyVault 1")
        #expect(mounted.mountPoint(of: Vault(name: "W", imagePath: "/nope.dmg")) == nil)
        #expect(HDIUtil.parseInfo(Data("junk".utf8)).isEmpty)
    }

    @Test("URL routing")
    func urls() throws {
        let parse = { VaultURL.parse(URL(string: $0)!) }
        #expect(parse("vaultbar://unlock/MyVault")! == (.unlock, "MyVault"))
        #expect(parse("vaultbar://Lock/My%20Vault%2F2/")! == (.lock, "My Vault/2"))
        #expect(parse("vaultbar://toggle")! == (.toggle, ""))
        #expect(parse("vaultbar://toggle/")! == (.toggle, ""))
        #expect(parse("vaultbar://open/My%20Vault")! == (.open, "My Vault"))
        #expect(parse("vaultbar://open/")! == (.open, ""))
        #expect(parse("vaultbar://format/MyVault") == nil)
        #expect(parse("https://unlock/MyVault") == nil)
        let made = VaultURL.make(.unlock, name: "My Vault \"$(x)\" כספת")
        #expect(!made.contains(" ") && !made.contains("\"") && !made.contains("$"))
        #expect(VaultURL.parse(URL(string: made)!)! == (.unlock, "My Vault \"$(x)\" כספת"))
    }

    @Test("slugs and script contents")
    func scripts() {
        #expect(Raycast.slug("MyVault") == "myvault")
        #expect(Raycast.slug("  My Tax/Docs 2026! ") == "my-tax-docs-2026")
        #expect(Raycast.slug("כספת") == "כספת")
        #expect(Raycast.slug("!!!") == "vault")
        let scripts = Raycast.scripts(for: [Vault(name: "My Vault", imagePath: "~/x")])
        #expect(Set(scripts.keys) == ["vaultbar-unlock-my-vault.sh", "vaultbar-lock-my-vault.sh", "vaultbar-open-my-vault.sh"])
        let unlock = scripts["vaultbar-unlock-my-vault.sh"]!
        #expect(unlock.hasPrefix("#!/bin/bash\n\n# @raycast.schemaVersion 1\n# @raycast.title Unlock My Vault\n"))
        #expect(unlock.contains("# @raycast.icon 🔓"))
        #expect(unlock.hasSuffix("open \"vaultbar://unlock/My%20Vault\"\n"))
        #expect(scripts["vaultbar-lock-my-vault.sh"]!.contains("open \"vaultbar://lock/My%20Vault\""))
        let open = scripts["vaultbar-open-my-vault.sh"]!
        #expect(open.contains("# @raycast.title Open My Vault\n") && open.contains("# @raycast.icon 📂"))
        #expect(open.hasSuffix("open \"vaultbar://open/My%20Vault\"\n"))
    }

    @Test("script sync writes executables and prunes only its own files")
    func scriptSync() throws {
        let dir = try tempDir()
        let foreign = ["other-script.sh", "vaultbar-notes.sh"]
        for name in foreign { try "#!/bin/bash\necho hi\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try Raycast.sync([Vault(name: "A", imagePath: "/a"), Vault(name: "B", imagePath: "/b")], in: dir)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("vaultbar-lock-a.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        try Raycast.sync([Vault(name: "B", imagePath: "/b")], in: dir)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names == Set(foreign + ["vaultbar-unlock-b.sh", "vaultbar-lock-b.sh", "vaultbar-open-b.sh"]))
    }

    @Test("hand-off only when nothing is in progress")
    func handOff() {
        func can(isAgent: Bool = false, disabled: Bool = false, atLogin: Bool = true, enabled: Bool = true,
                 activity: Activity = Activity()) -> Bool {
            canHandOff(isAgent: isAgent, handOffDisabled: disabled, launchAtLogin: atLogin, agentEnabled: enabled,
                       activity: activity)
        }
        #expect(can())
        #expect(!can(isAgent: true))
        #expect(!can(disabled: true))
        #expect(!can(atLogin: false))
        #expect(!can(enabled: false))
        #expect(!can(activity: Activity(prompting: true)))
        #expect(!can(activity: Activity(inFlight: 1))) // a lock's detach still running
        #expect(!can(activity: Activity(pendingForce: 1)))
        #expect(!can(activity: Activity(paused: true)))
        #expect(!can(activity: Activity(uiOpen: true)))
    }

    @Test("relaunch for an update only when the bundle changed (or vanished) and nothing is in progress")
    func relaunchForUpdate() {
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.3 (4)", activity: Activity()))
        #expect(shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity()))
        #expect(shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.3 (5)", activity: Activity()))
        #expect(shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: nil, activity: Activity())) // moved away
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity(inFlight: 1)))
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity(prompting: true)))
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity(paused: true)))
    }

    @Test("helper scripts: verified hand-off with fallback, and relaunch by path once the bundle is back")
    func helperScripts() throws {
        let handOff = HelperScript.handOff(uid: 501, label: "com.example.agent")
        #expect(handOff.hasPrefix("sleep 1; /bin/launchctl kickstart gui/501/com.example.agent; "))
        #expect(handOff.contains("/usr/bin/pgrep -x -U 501 VaultBar >/dev/null && exit 0"))
        #expect(handOff.hasSuffix(#"/usr/bin/open -n "$1" --args --no-handoff"#))
        #expect(!handOff.contains("kickstart gui/501/com.example.agent ||")) // kickstart's 0 proves nothing

        // Run the relaunch script for real with `open` swapped for `echo`, against a temp "bundle".
        let bundle = try tempDir().appendingPathComponent("My App.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let script = HelperScript.relaunch().replacingOccurrences(of: "sleep 1; ", with: "")
            .replacingOccurrences(of: "/usr/bin/open -n", with: "echo opened")
        let result = Tool.run("/bin/sh", ["-c", script, "sh", bundle.path])
        #expect(result.ok && result.stdout == "opened \(bundle.path)\n")
    }

    @Test("what each action does: lock, open in Finder, or prompt (and open after) per openAfterUnlock")
    func steps() {
        for setting in [false, true] {
            #expect(VaultAction.unlock.step(unlocked: false, openAfterUnlock: setting) == .promptUnlock(thenOpen: setting))
            #expect(VaultAction.toggle.step(unlocked: false, openAfterUnlock: setting) == .promptUnlock(thenOpen: setting))
            #expect(VaultAction.open.step(unlocked: false, openAfterUnlock: setting) == .promptUnlock(thenOpen: true))
            #expect(VaultAction.open.step(unlocked: true, openAfterUnlock: setting) == .openInFinder)
            #expect(VaultAction.unlock.step(unlocked: true, openAfterUnlock: setting) == .nothing)
            #expect(VaultAction.lock.step(unlocked: true, openAfterUnlock: setting) == .lock)
            #expect(VaultAction.toggle.step(unlocked: true, openAfterUnlock: setting) == .lock)
            #expect(VaultAction.lock.step(unlocked: false, openAfterUnlock: setting) == .nothing)
        }
    }

    @Test("sync-folder warning")
    func syncFolder() throws {
        let home = try tempDir()
        let fm = FileManager.default
        for sub in ["Library/Mobile Documents/x", "Library/CloudStorage/Dropbox/y", "Desktop", "Documents/z",
                    "Sync/inner/deep", "Syno/a", "Plain/Vaults", "DocumentsArchive"] {
            try fm.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: home.appendingPathComponent("Sync/.stfolder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Syno/.SynologyWorkingDirectory"), withIntermediateDirectories: true)
        let warn = { SyncFolder.warning(for: home.appendingPathComponent($0), home: home) }
        #expect(warn("Library/Mobile Documents/x")?.contains("iCloud Drive") == true)
        #expect(warn("Library/CloudStorage/Dropbox/y") != nil)
        #expect(warn("Desktop") != nil)
        #expect(warn("Documents/z") != nil)
        #expect(warn("Sync/inner/deep")?.contains("Syncthing") == true)
        #expect(warn("Syno/a")?.contains("Synology") == true)
        #expect(warn("Plain/Vaults") == nil)
        #expect(warn("DocumentsArchive") == nil)
    }

    @Test("secret wipe; an empty secret never reaches a tool")
    func secret() {
        let secret = Secret("pässword")
        #expect(!secret.isEmpty)
        secret.wipe()
        #expect(secret.isEmpty)
        let result = HDIUtil.attach("/nonexistent.sparsebundle", secret: Secret(""))
        #expect(result.status == -1 && result.output == "Empty password.")
    }

    @Test("force after the grace period only if the user hasn't come back")
    func forceAfterGrace() {
        let idle15: TimeInterval = 15 * 60
        #expect(AutoLockTrigger.sleep.shouldForce(screenLocked: false, idleSeconds: 0, idleMinutes: 15, paused: true))
        #expect(AutoLockTrigger.screenLock.shouldForce(screenLocked: true, idleSeconds: 0, idleMinutes: 15, paused: false))
        #expect(!AutoLockTrigger.screenLock.shouldForce(screenLocked: false, idleSeconds: 0, idleMinutes: 15, paused: false))
        #expect(!AutoLockTrigger.screenLock.shouldForce(screenLocked: true, idleSeconds: 0, idleMinutes: 15, paused: true))
        #expect(AutoLockTrigger.idle.shouldForce(screenLocked: false, idleSeconds: idle15 + 60, idleMinutes: 15, paused: false))
        #expect(AutoLockTrigger.idle.shouldForce(screenLocked: false, idleSeconds: idle15, idleMinutes: 15, paused: false))
        #expect(!AutoLockTrigger.idle.shouldForce(screenLocked: false, idleSeconds: 5, idleMinutes: 15, paused: false))
        #expect(!AutoLockTrigger.idle.shouldForce(screenLocked: true, idleSeconds: idle15 + 60, idleMinutes: 15, paused: true))
        #expect(!AutoLockTrigger.idle.shouldForce(screenLocked: false, idleSeconds: idle15 + 60, idleMinutes: 0, paused: false))
    }

    @Test("auto-lock pause: skips idle and screen lock, never sleep, expires once after 1 hour")
    func pause() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let settings = AutoLock(onSleep: true, onScreenLock: true, idleMinutes: 15)
        let longIdle: TimeInterval = 3 * 3600
        var pause = AutoLockPause()
        #expect(!pause.isActive(at: t0))
        #expect(pause.shouldAutoLock(.idle, settings: settings, idleSeconds: 15 * 60, at: t0))
        #expect(!pause.shouldAutoLock(.idle, settings: settings, idleSeconds: 15 * 60 - 1, at: t0))
        #expect(pause.shouldAutoLock(.screenLock, settings: settings, at: t0))

        pause.start(at: t0)
        let almost = t0.addingTimeInterval(59 * 60)
        #expect(pause.isActive(at: almost))
        #expect(!pause.shouldAutoLock(.idle, settings: settings, idleSeconds: longIdle, at: almost))
        #expect(!pause.shouldAutoLock(.screenLock, settings: settings, at: almost))
        #expect(pause.shouldAutoLock(.sleep, settings: settings, at: almost))
        let earlyExpire = pause.expire(at: almost)
        #expect(!earlyExpire)

        let end = t0.addingTimeInterval(60 * 60)
        #expect(!pause.isActive(at: end))
        let first = pause.expire(at: end), second = pause.expire(at: end)
        #expect(first && !second)
        #expect(pause.until == nil)
        // already idle when it ends -> the normal idle lock runs
        #expect(pause.shouldAutoLock(.idle, settings: settings, idleSeconds: longIdle, at: end))

        pause.start(at: t0)
        pause.resume()
        #expect(!pause.isActive(at: t0))
        #expect(pause.shouldAutoLock(.screenLock, settings: settings, at: t0))

        let off = AutoLock(onSleep: false, onScreenLock: false, idleMinutes: 0)
        #expect(!pause.shouldAutoLock(.sleep, settings: off, at: t0))
        #expect(!pause.shouldAutoLock(.screenLock, settings: off, at: t0))
        #expect(!pause.shouldAutoLock(.idle, settings: off, idleSeconds: longIdle, at: t0))
    }
}

/// Real disk images, gated: `VAULTBAR_E2E=1 swift test --filter endToEnd`.
/// Works only in .scratch/ with a throwaway image and volume VaultBarTest; never touches anything else.
@Test("end to end with a throwaway vault", .enabled(if: ProcessInfo.processInfo.environment["VAULTBAR_E2E"] == "1"))
func endToEnd() throws {
    let scratch = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".scratch")
    let fm = FileManager.default
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    try #require(!fm.fileExists(atPath: "/Volumes/VaultBarTest"), "a VaultBarTest volume is already mounted")
    let image = scratch.appendingPathComponent("VaultBarTest.sparsebundle").path
    let plain = scratch.appendingPathComponent("plain.dmg").path
    let password = "dummy pass #1 é"
    let vault = Vault(name: "VaultBarTest", imagePath: image)
    defer {
        if let mountPoint = HDIUtil.mounted().mountPoint(of: vault) { _ = HDIUtil.detach(mountPoint, force: true) }
        for name in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] {
            try? fm.removeItem(at: scratch.appendingPathComponent(name))
        }
    }

    // 1. create
    let created = HDIUtil.create(imagePath: image, volumeName: "VaultBarTest", sizeGB: 1, secret: Secret(password))
    print("e2e create: status \(created.status) \(created.output)")
    try #require(created.ok)
    #expect(HDIUtil.isEncrypted(image))
    let plainResult = Tool.run("/usr/bin/hdiutil", ["create", "-size", "1m", "-fs", "HFS+", "-volname", "VaultBarPlain", plain])
    try #require(plainResult.ok, "\(plainResult.output)")
    #expect(!HDIUtil.isEncrypted(plain))

    // 2. attach
    let attached = HDIUtil.attach(image, secret: Secret(password))
    print("e2e attach: status \(attached.status)")
    try #require(attached.ok, "\(attached.output)")
    let mountPoint = try #require(HDIUtil.mounted().mountPoint(of: vault))
    print("e2e mounted at \(mountPoint)")
    #expect(mountPoint == "/Volumes/VaultBarTest")

    // 3. write a file; an open handle makes a clean detach busy
    let file = mountPoint + "/hello.txt"
    try "hello vault".write(toFile: file, atomically: true, encoding: .utf8)
    let handle = try #require(FileHandle(forReadingAtPath: file))
    let busy = HDIUtil.detach(mountPoint, force: false)
    print("e2e busy detach: status \(busy.status) \(busy.output)")
    #expect(!busy.ok && busy.isBusy)
    try handle.close()

    // 4. detach
    let detached = HDIUtil.detach(mountPoint, force: false)
    print("e2e detach: status \(detached.status) \(detached.output)")
    #expect(detached.ok)
    #expect(HDIUtil.mounted().mountPoint(of: vault) == nil)

    // 5. wrong password (a prefix of the right one, so truncation would show) must fail
    let wrong = HDIUtil.attach(image, secret: Secret(String(password.dropLast())))
    print("e2e wrong password: status \(wrong.status) \(wrong.output)")
    #expect(!wrong.ok && wrong.isAuthError)
    #expect(HDIUtil.mounted().mountPoint(of: vault) == nil)

    // 6. right password, file is there
    let again = HDIUtil.attach(image, secret: Secret(password))
    try #require(again.ok, "\(again.output)")
    let mountPoint2 = try #require(HDIUtil.mounted().mountPoint(of: vault))
    let content = try String(contentsOfFile: mountPoint2 + "/hello.txt", encoding: .utf8)
    print("e2e re-attach: file says \"\(content)\"")
    #expect(content == "hello vault")

    // 7. detach (force path)
    let forced = HDIUtil.detach(mountPoint2, force: true)
    print("e2e force detach: status \(forced.status) \(forced.output)")
    #expect(forced.ok)
    #expect(HDIUtil.mounted().mountPoint(of: vault) == nil)
}
