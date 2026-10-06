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

    @Test("mountedIfKnown reads hdiutil info (nil only when it can't)")
    func mountedIfKnown() {
        #expect(HDIUtil.mountedIfKnown() != nil)
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
            ["image-path": image.path, "writeable": false, "system-entities": [
                ["dev-entry": "/dev/disk8"],
                ["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/MyVault 1"],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let mounted = HDIUtil.parseInfo(data)
        #expect(mounted.count == 1)
        #expect(mounted.mountPoint(of: Vault(name: "V", imagePath: link.path)) == "/Volumes/MyVault 1")
        #expect(mounted.mount(of: Vault(name: "V", imagePath: link.path))?.readOnly == true)
        #expect(mounted.mountPoint(of: Vault(name: "W", imagePath: "/nope.dmg")) == nil)
        #expect(HDIUtil.parseInfo(Data("junk".utf8)).isEmpty)
    }

    @Test("URL routing")
    func urls() throws {
        let parse = { VaultURL.parse(URL(string: $0)!) }
        func request(_ action: VaultAction, _ name: String, readOnly: Bool? = nil) -> VaultRequest {
            VaultRequest(action: action, name: name, readOnly: readOnly)
        }
        #expect(parse("vaultbar://unlock/MyVault") == request(.unlock, "MyVault"))
        #expect(parse("vaultbar://Lock/My%20Vault%2F2/") == request(.lock, "My Vault/2"))
        #expect(parse("vaultbar://toggle") == request(.toggle, ""))
        #expect(parse("vaultbar://toggle/") == request(.toggle, ""))
        #expect(parse("vaultbar://open/My%20Vault") == request(.open, "My Vault"))
        #expect(parse("vaultbar://open/") == request(.open, ""))
        #expect(parse("vaultbar://unlock/MyVault?readonly=1") == request(.unlock, "MyVault", readOnly: true))
        #expect(parse("vaultbar://unlock/MyVault?readonly=0") == request(.unlock, "MyVault", readOnly: false))
        #expect(parse("vaultbar://lockall") == request(.lockAll, ""))
        #expect(parse("vaultbar://format/MyVault") == nil)
        #expect(parse("https://unlock/MyVault") == nil)
        let made = VaultURL.make(.unlock, name: "My Vault \"$(x)\" כספת")
        #expect(!made.contains(" ") && !made.contains("\"") && !made.contains("$"))
        #expect(VaultURL.parse(URL(string: made)!) == request(.unlock, "My Vault \"$(x)\" כספת"))
        #expect(VaultURL.make(.unlock, name: "A B", readOnly: true) == "vaultbar://unlock/A%20B?readonly=1")
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

    @Test("vault mount options: optional in the file, false stored as no key, validated")
    func mountOptions() throws {
        var vault = Vault(name: "MyVault", imagePath: "/Users/alice/Vaults/MyVault.sparsebundle")
        #expect(!vault.isHidden && !vault.isReadOnly && vault.expandedMountPoint == nil)
        vault.isReadOnly = true
        vault.isHidden = true
        vault.mountPoint = "~/Vaults/mnt/MyVault"
        let encoded = String(decoding: try JSONEncoder().encode(vault), as: UTF8.self)
        #expect(encoded.contains("\"readOnly\":true") && encoded.contains("\"hidden\":true"))
        vault.isHidden = false
        #expect(!String(decoding: try JSONEncoder().encode(vault), as: UTF8.self).contains("hidden"))
        #expect(vault.expandedMountPoint == NSString(string: "~/Vaults/mnt/MyVault").expandingTildeInPath)
        let old = try JSONDecoder().decode(Vault.self, from: Data(#"{"name": "A", "imagePath": "/a"}"#.utf8))
        #expect(old == Vault(name: "A", imagePath: "/a"))

        var config = sample
        config.vaults[0].mountPoint = "relative/mnt"
        #expect(config.validate() != nil)
        config.vaults[0].mountPoint = "/tmp/vaultbar-test-mnt/A"
        #expect(config.validate() == nil)
        config.vaults.append(Vault(name: "Other", imagePath: "/b", mountPoint: "/tmp/vaultbar-test-mnt/A"))
        #expect(config.validate() == "Two vaults use the same mount folder")
        // A private mount folder in a synced folder would sync the plaintext.
        let synced = try tempDir()
        try FileManager.default.createDirectory(at: synced.appendingPathComponent(".stfolder"), withIntermediateDirectories: true)
        #expect(Config.problem(withMountPoint: synced.appendingPathComponent("mnt/A").path)?.contains("synced") == true)
    }

    @Test("attach arguments: always -stdinpass, read-only / hidden / private mount on request")
    func attachArguments() {
        #expect(HDIUtil.attachArguments("/v.sparsebundle") == ["attach", "-stdinpass", "/v.sparsebundle"])
        #expect(HDIUtil.attachArguments("/v.sparsebundle", mountPoint: "/m/A", hidden: true, readOnly: true)
                == ["attach", "-stdinpass", "-readonly", "-nobrowse", "-mountpoint", "/m/A", "/v.sparsebundle"])
        // Two passwords on one stdin for chpass; a line break in either would split them wrongly.
        let joined = Secret(joining: Secret("old"), Secret("new"))
        #expect(!joined.isEmpty && !Secret("a b").containsLineBreakOrNUL && Secret("a\nb").containsLineBreakOrNUL)
        let refused = HDIUtil.changePassword("/nonexistent.sparsebundle", old: Secret("a\nb"), new: Secret("c"))
        #expect(refused.status == -1)
    }

    @Test("private mount folder: created 0700 only when missing or empty, removed only when empty")
    func mountFolder() throws {
        let base = try tempDir()
        let folder = base.appendingPathComponent("mnt/MyVault").path
        #expect(MountFolder.prepare(folder) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(MountFolder.prepare(folder) == nil) // empty and already there: fine
        chmod(folder, 0o755)
        #expect(MountFolder.prepare(folder) == nil)
        let tightened = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(tightened == 0o700) // an existing empty folder is made private too
        try "x".write(toFile: folder + "/stray.txt", atomically: true, encoding: .utf8)
        #expect(MountFolder.prepare(folder)?.contains("isn't empty") == true)
        MountFolder.remove(folder)
        #expect(FileManager.default.fileExists(atPath: folder)) // not empty: kept
        try FileManager.default.removeItem(atPath: folder + "/stray.txt")
        MountFolder.remove(folder)
        #expect(!FileManager.default.fileExists(atPath: folder))
        let file = base.appendingPathComponent("file").path
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(MountFolder.prepare(file)?.contains("is a file") == true)
    }

    @Test("stale private mount folders: configured, not mounted, not being unlocked right now")
    func staleFolders() {
        let a = Vault(name: "A", imagePath: "/Users/alice/Vaults/A.sparsebundle", mountPoint: "/Users/alice/mnt/A")
        let b = Vault(name: "B", imagePath: "/Users/alice/Vaults/B.sparsebundle", mountPoint: "/Users/alice/mnt/B")
        let c = Vault(name: "C", imagePath: "/Users/alice/Vaults/C.sparsebundle") // /Volumes: never touched
        let mounted = [HDIUtil.resolve(a.imagePath): Mount(path: "/Users/alice/mnt/A", readOnly: false)]
        #expect(MountFolder.stale(vaults: [a, b, c], mounted: mounted) == ["/Users/alice/mnt/B"])
        #expect(MountFolder.stale(vaults: [a, b, c], mounted: mounted, attaching: ["B"]).isEmpty)
        #expect(MountFolder.stale(vaults: [a, b, c], mounted: [:]) == ["/Users/alice/mnt/A", "/Users/alice/mnt/B"])
    }

    @Test("CLI: parse, usage errors, never a password")
    func cli() {
        #expect(CLI.parse(["status"]) == .status(json: false))
        #expect(CLI.parse(["status", "--json"]) == .status(json: true))
        #expect(CLI.parse(["path", "My Vault"]) == .path("My Vault"))
        #expect(CLI.parse(["path"]) == .path(""))
        #expect(CLI.parse(["lock", "A", "--wait", "5"]) == .lock("A", wait: 5))
        #expect(CLI.parse(["lock", "--all"]) == .lockAll(wait: nil))
        #expect(CLI.parse(["unlock", "A", "--readonly", "--wait", "60"]) == .unlock("A", readOnly: true, wait: 60))
        #expect(CLI.parse(["unlock"]) == .unlock("", readOnly: false, wait: nil))
        #expect(CLI.parse(["open", "A"]) == .open("A"))
        #expect(CLI.parse(["help"]) == .help)
        for bad in [[], ["bogus"], ["status", "A"], ["lock", "--all", "A"], ["unlock", "A", "B"], ["unlock", "--wait"],
                    ["unlock", "--wait", "-1"], ["unlock", "--password", "x"], ["unlock", "A", "--stdin"], ["path", "--json"]] {
            #expect(CLI.parse(bad) == nil, "\(bad)")
        }
        let config = sample
        let vault = config.vaults[0]
        let locked = CLI.statusText(config, mounted: [:])
        #expect(locked == "MyVault (default): locked")
        let mounted = [HDIUtil.resolve(vault.imagePath): Mount(path: "/Volumes/MyVault", readOnly: true)]
        #expect(CLI.statusText(config, mounted: mounted) == "MyVault (default): unlocked at /Volumes/MyVault (read-only)")
        let json = CLI.statusJSON(config, mounted: mounted)
        #expect(json.contains(#""mountPoint" : "/Volumes/MyVault""#) && json.contains(#""readOnly" : true"#))
        #expect(CLIExit.usage.rawValue == 64 && CLIExit.timeout.rawValue == 3 && CLIExit.noSuchVault.rawValue == 2)
    }

    @Test("panic presets, event ring, password advice, pause duration")
    func smallPieces() {
        #expect(PanicHotkey.default.title == "⌃⌥⌘L" && PanicHotkey.preset("off") == nil)
        #expect(Set(PanicHotkey.presets.map(\.id)).count == PanicHotkey.presets.count)
        #expect(Config.seed.panicHotkey == "ctrl-opt-cmd-L" && Config.seed.panicForces)

        var log = EventLog(capacity: 3)
        for i in 1...5 { log.add("event \(i)") }
        #expect(log.events.map(\.text) == ["event 3", "event 4", "event 5"] && log.last?.text == "event 5")

        #expect(PasswordAdvice.warnings(for: "short", names: []) == ["It's shorter than 12 characters."])
        #expect(PasswordAdvice.warnings(for: "my-personal-vault-2026!", names: ["Personal"]) == ["It contains the vault's name."])
        #expect(PasswordAdvice.warnings(for: "correct horse battery", names: ["Personal", "ab"]).isEmpty)

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var pause = AutoLockPause()
        pause.start(at: t0, duration: 15 * 60)
        #expect(pause.isActive(at: t0.addingTimeInterval(14 * 60)) && !pause.isActive(at: t0.addingTimeInterval(15 * 60)))
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

    @Test("relaunch for an update only when a different bundle is in place and nothing is in progress")
    func relaunchForUpdate() {
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.3 (4)", activity: Activity()))
        #expect(shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity()))
        #expect(shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.3 (5)", activity: Activity()))
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: nil, activity: Activity())) // mid-move: wait
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity(inFlight: 1)))
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity(prompting: true)))
        #expect(!shouldRelaunchForUpdate(running: "0.1.3 (4)", onDisk: "0.1.4 (5)", activity: Activity(paused: true)))
    }

    @Test("succession: marker and ack round-trip; who waits, who may exit")
    func succession() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let marker = Succession.parseMarker(Succession.markerText(pid: 4242, date: now))
        #expect(marker == Succession.Marker(pid: 4242, date: now))
        #expect(Succession.parseMarker("junk") == nil && Succession.parseMarker("12") == nil)
        let ack = Succession.parseAck(Succession.ackText(successor: 5000, predecessor: 4242))
        #expect(ack == Succession.Ack(successor: 5000, predecessor: 4242))
        #expect(Succession.parseAck("5000") == nil)

        // The successor waits for a fresh, alive predecessor that is the rival (or only holds the lock) ...
        #expect(Succession.shouldWait(for: marker, markerPIDAlive: true, rivalPID: 4242, now: now))
        #expect(Succession.shouldWait(for: marker, markerPIDAlive: true, rivalPID: nil, now: now))
        // ... but not for a different rival, a dead pid, a stale marker, or no marker: those make it exit as before.
        #expect(!Succession.shouldWait(for: marker, markerPIDAlive: true, rivalPID: 777, now: now))
        #expect(!Succession.shouldWait(for: marker, markerPIDAlive: false, rivalPID: 4242, now: now))
        #expect(!Succession.shouldWait(for: marker, markerPIDAlive: true, rivalPID: 4242,
                                       now: now.addingTimeInterval(Succession.markerLifetime)))
        #expect(!Succession.shouldWait(for: nil, markerPIDAlive: true, rivalPID: 4242, now: now))

        // The predecessor exits only for its own, live successor, and only when idle.
        #expect(Succession.mayExit(ack: ack, myPID: 4242, successorAlive: true, activity: Activity()))
        #expect(!Succession.mayExit(ack: ack, myPID: 4242, successorAlive: false, activity: Activity()))
        #expect(!Succession.mayExit(ack: ack, myPID: 9999, successorAlive: true, activity: Activity())) // someone else's
        #expect(!Succession.mayExit(ack: nil, myPID: 4242, successorAlive: true, activity: Activity()))
        #expect(!Succession.mayExit(ack: ack, myPID: 4242, successorAlive: true, activity: Activity(prompting: true)))
        #expect(!Succession.mayExit(ack: Succession.Ack(successor: 4242, predecessor: 4242), myPID: 4242,
                                    successorAlive: true, activity: Activity()))
        // Hand-off: kickstart again while waiting, and give up (stay) after the last attempt had time to work.
        #expect(Succession.handOffKickstarts.first == 0 && Succession.handOffKickstarts.count > 1)
        #expect(Succession.handOffTimeout > Succession.handOffKickstarts.last!)
        #expect(Succession.successorWait < Succession.updateTimeout)
    }

    @Test("login agent plist: runs the executable by path, restarts after a crash only")
    func loginAgentPlist() throws {
        let data = LoginAgentPlist.data(label: "com.example.login", executable: "/Applications/Example.app/Contents/MacOS/Example",
                                        bundleID: "com.example")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.example.login")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.example"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(LoginAgentPlist.program(in: data) == "/Applications/Example.app/Contents/MacOS/Example")
        #expect(LoginAgentPlist.program(in: Data("junk".utf8)) == nil)

        let running = "gui/501/com.example.login = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = 0\n}"
        #expect(LaunchdJob.runningPID(launchctlPrint: running) == 4242)
        #expect(LaunchdJob.runningPID(launchctlPrint: running.replacingOccurrences(of: "\tpid = 4242\n", with: "")) == nil)
        #expect(LaunchdJob.runningPID(launchctlPrint: nil) == nil)
    }

    @Test("menu bar clicks: left toggles, right or Control-click opens the menu, ⌥-click locks all")
    func statusClicks() {
        func click(right: Bool = false, control: Bool = false, option: Bool = false, hasDefault: Bool = true) -> StatusClick {
            StatusClick.action(rightButton: right, control: control, option: option, hasDefault: hasDefault)
        }
        #expect(click() == .toggleDefault)
        #expect(click(right: true) == .menu)
        #expect(click(control: true) == .menu)            // Control-click = right-click
        #expect(click(control: true, option: true) == .menu)
        #expect(click(option: true) == .lockAll)
        #expect(click(right: true, option: true) == .menu) // ⌥-right-click: still the menu
        #expect(click(hasDefault: false) == .menu)
    }

    @Test("unregister: lock every mounted vault first; busy refuses unless forced")
    func unregisterLock() {
        let a = Vault(name: "A", imagePath: "/Users/alice/Vaults/A.sparsebundle")
        let b = Vault(name: "B", imagePath: "/Users/alice/Vaults/B.sparsebundle")
        let c = Vault(name: "C", imagePath: "/Users/alice/Vaults/C.sparsebundle") // locked: untouched
        let mounted = [HDIUtil.resolve(a.imagePath): Mount(path: "/Volumes/A", readOnly: false),
                       HDIUtil.resolve(b.imagePath): Mount(path: "/Volumes/B", readOnly: false)]
        let ok = ToolResult(status: 0, stdout: "", output: "")
        let busy = ToolResult(status: 16, stdout: "", output: "hdiutil: couldn't unmount - Resource busy")
        var calls: [String] = []
        let bBusyUntilForced: (String, Bool) -> ToolResult = { path, force in
            calls.append("\(path) \(force)")
            return path == "/Volumes/B" && !force ? busy : ok
        }
        let clean = UnregisterLock.lockAll([a, b, c], mounted: mounted, force: false, detach: bBusyUntilForced)
        #expect(clean.locked == ["A"] && !clean.mayUnregister)
        #expect(clean.stillUnlocked.map(\.vault) == ["B"] && clean.stillUnlocked[0].reason.contains("--force"))
        #expect(calls == ["/Volumes/A false", "/Volumes/B false"]) // never forced without --force
        calls = []
        let forced = UnregisterLock.lockAll([a, b, c], mounted: mounted, force: true, detach: bBusyUntilForced)
        #expect(forced.locked == ["A", "B"] && forced.mayUnregister)
        #expect(calls == ["/Volumes/A false", "/Volumes/B false", "/Volumes/B true"]) // clean first, then force
        let failing = UnregisterLock.lockAll([a], mounted: mounted, force: true) { _, _ in
            ToolResult(status: 1, stdout: "", output: "hdiutil: detach failed")
        }
        #expect(!failing.mayUnregister && failing.stillUnlocked == [UnregisterLock.Failure(vault: "A", reason: "hdiutil: detach failed")])
        #expect(UnregisterLock.lockAll([a, b], mounted: [:], force: false, detach: { _, _ in ok }).mayUnregister) // nothing mounted
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

    // 8. read-only + hidden at a private mount folder that exists only while unlocked
    let folder = scratch.appendingPathComponent("mnt/VaultBarTest").path
    #expect(!fm.fileExists(atPath: folder))
    #expect(MountFolder.prepare(folder) == nil)
    let privateMount = HDIUtil.attach(image, mountPoint: folder, hidden: true, readOnly: true, secret: Secret(password))
    print("e2e private read-only attach: status \(privateMount.status)")
    try #require(privateMount.ok, "\(privateMount.output)")
    let mount = try #require(HDIUtil.mounted().mount(of: vault))
    print("e2e private mount: \(mount.path) readOnly=\(mount.readOnly)")
    #expect(HDIUtil.resolve(mount.path) == HDIUtil.resolve(folder) && mount.readOnly)
    #expect(try String(contentsOfFile: folder + "/hello.txt", encoding: .utf8) == "hello vault")
    #expect(throws: (any Error).self) { try "nope".write(toFile: folder + "/new.txt", atomically: false, encoding: .utf8) }
    let visible = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    #expect(!visible.contains { HDIUtil.resolve($0.path) == HDIUtil.resolve(folder) }) // -nobrowse
    let config = Config(defaultVault: vault.name, autoLock: AutoLock(onSleep: true, onScreenLock: true, idleMinutes: 15),
                        launchAtLogin: false, vaults: [Vault(name: vault.name, imagePath: image, mountPoint: folder, hidden: true)])
    let json = CLI.statusJSON(config, mounted: HDIUtil.mounted())
    print("e2e cli status --json: \(json.replacingOccurrences(of: "\n", with: " "))")
    #expect(json.contains(#""readOnly" : true"#) && json.contains(#""unlocked" : true"#) && json.contains(folder))
    let detachedPrivate = HDIUtil.detach(mount.path, force: false)
    #expect(detachedPrivate.ok)
    MountFolder.remove(folder)
    print("e2e private folder after lock exists=\(fm.fileExists(atPath: folder))")
    #expect(!fm.fileExists(atPath: folder))
    #expect(CLI.statusText(config, mounted: HDIUtil.mounted()) == "VaultBarTest (default): locked")

    // 8b. ejected outside VaultBar (plain hdiutil detach): the cleanup finds and removes the empty folder
    #expect(MountFolder.prepare(folder) == nil)
    try #require(HDIUtil.attach(image, mountPoint: folder, hidden: true, secret: Secret(password)).ok)
    let outside = Tool.run("/usr/bin/hdiutil", ["detach", folder])
    print("e2e outside detach: status \(outside.status) folder left behind=\(fm.fileExists(atPath: folder))")
    #expect(outside.ok && fm.fileExists(atPath: folder)) // hdiutil leaves it
    let stale = MountFolder.stale(vaults: config.vaults, mounted: HDIUtil.mounted())
    #expect(stale.map(HDIUtil.resolve) == [HDIUtil.resolve(folder)])
    stale.forEach(MountFolder.remove)
    print("e2e after cleanup folder exists=\(fm.fileExists(atPath: folder))")
    #expect(!fm.fileExists(atPath: folder))

    // 8c. --unregister-login-item's locking, for real: busy refuses, --force locks, the private folder goes
    #expect(MountFolder.prepare(folder) == nil)
    try #require(HDIUtil.attach(image, mountPoint: folder, hidden: true, secret: Secret(password)).ok)
    let openFile = try #require(FileHandle(forReadingAtPath: folder + "/hello.txt"))
    let refused = UnregisterLock.lockAll(config.vaults, mounted: HDIUtil.mounted(), force: false, detach: HDIUtil.detach)
    print("e2e unregister without --force: locked=\(refused.locked) still=\(refused.stillUnlocked.map(\.vault))")
    #expect(!refused.mayUnregister && HDIUtil.mounted().mountPoint(of: vault) != nil)
    let forcedLock = UnregisterLock.lockAll(config.vaults, mounted: HDIUtil.mounted(), force: true, detach: HDIUtil.detach)
    try openFile.close()
    print("e2e unregister --force: locked=\(forcedLock.locked) folder exists=\(fm.fileExists(atPath: folder))")
    #expect(forcedLock.mayUnregister && forcedLock.locked == ["VaultBarTest"])
    #expect(HDIUtil.mounted().mountPoint(of: vault) == nil && !fm.fileExists(atPath: folder))

    // 9. change the password: the new one opens it, the old one no longer does, the data is untouched
    let newPassword = "second pass ü 2"
    let changed = HDIUtil.changePassword(image, old: Secret(password), new: Secret(newPassword))
    print("e2e change password: status \(changed.status) \(changed.output)")
    try #require(changed.ok)
    let oldAfter = HDIUtil.attach(image, mountPoint: folder, secret: Secret(password))
    print("e2e old password after change: status \(oldAfter.status) \(oldAfter.output)")
    #expect(!oldAfter.ok && oldAfter.isAuthError)
    #expect(MountFolder.prepare(folder) == nil)
    let newAfter = HDIUtil.attach(image, mountPoint: folder, hidden: true, readOnly: true, secret: Secret(newPassword))
    print("e2e new password after change: status \(newAfter.status)")
    try #require(newAfter.ok, "\(newAfter.output)")
    #expect(try String(contentsOfFile: folder + "/hello.txt", encoding: .utf8) == "hello vault")
    #expect(HDIUtil.detach(folder, force: true).ok)
    MountFolder.remove(folder)
    #expect(!fm.fileExists(atPath: folder))
}
