import Foundation

public struct Vault: Codable, Equatable, Sendable {
    public var name: String
    /// May start with `~`; stored as the user typed or picked it.
    public var imagePath: String
    /// Private mount folder (may start with `~`), created right before unlock and removed after lock.
    /// nil: macOS mounts it under /Volumes.
    public var mountPoint: String?
    /// Kept out of Finder's sidebar, Desktop and file pickers (`-nobrowse`). nil = false.
    public var hidden: Bool?
    /// Unlock read-only unless asked otherwise. nil = false.
    public var readOnly: Bool?

    public init(name: String, imagePath: String, mountPoint: String? = nil, hidden: Bool? = nil, readOnly: Bool? = nil) {
        self.name = name
        self.imagePath = imagePath
        self.mountPoint = mountPoint
        self.hidden = hidden
        self.readOnly = readOnly
    }

    public var expandedPath: String { NSString(string: imagePath).expandingTildeInPath }
    public var expandedMountPoint: String? { mountPoint.map { NSString(string: $0).expandingTildeInPath } }
    // false is stored as a missing key, so configs stay as small as before.
    public var isHidden: Bool { get { hidden ?? false } set { hidden = newValue ? true : nil } }
    public var isReadOnly: Bool { get { readOnly ?? false } set { readOnly = newValue ? true : nil } }
}

public struct AutoLock: Codable, Equatable, Sendable {
    public var onSleep: Bool
    public var onScreenLock: Bool
    /// 0 turns idle locking off.
    public var idleMinutes: Int
}

/// `~/.config/vaultbar/vaults.json`. Holds no secrets, ever.
public struct Config: Codable, Equatable, Sendable {
    public var defaultVault: String?
    public var autoLock: AutoLock
    public var launchAtLogin: Bool
    public var vaults: [Vault]
    /// Where Raycast Script Commands go (may start with `~`). nil: no scripts are written.
    public var raycastScriptsDir: String?
    /// Open the vault in Finder after every unlock (the `open` action always does).
    public var openAfterUnlock = false
    /// Global hotkey that locks every vault (a `PanicHotkey` preset id, or "off").
    public var panicHotkey = PanicHotkey.default.id
    /// The panic hotkey force-locks busy vaults instead of asking.
    public var panicForces = true

    /// `~/.config/vaultbar/vaults.json`, or `<VBConfigDirectory>/vaults.json` when the app bundle's Info.plist sets
    /// that key (the launchd test build keeps its config in a scratch folder).
    public static var url: URL {
        if let directory = Bundle.main.object(forInfoDictionaryKey: "VBConfigDirectory") as? String {
            return URL(fileURLWithPath: directory).appendingPathComponent("vaults.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vaultbar/vaults.json")
    }

    /// First run: no vaults yet; the menu offers New Vault… and Add Existing Vault….
    public static let seed = Config(
        defaultVault: nil,
        autoLock: AutoLock(onSleep: true, onScreenLock: true, idleMinutes: 15),
        launchAtLogin: true,
        vaults: [],
        raycastScriptsDir: nil
    )

    public var raycastDirectory: URL? {
        raycastScriptsDir.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    /// nil when the file doesn't exist yet (first run). Throws on unreadable JSON so it never gets overwritten.
    public static func load(from url: URL = Config.url) throws -> Config? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = Config.url) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Error message, or nil when valid.
    public func validate() -> String? {
        var slugs = Set<String>()
        for vault in vaults {
            if let problem = Config.problem(withName: vault.name) { return problem }
            // Raycast script names come from the slug, so it has to be unique too.
            if !slugs.insert(Raycast.slug(vault.name)).inserted {
                return "Two vaults have the same (or too similar) name: \(vault.name)"
            }
            if vault.imagePath.isEmpty { return "\(vault.name) has no image path" }
            if let mountPoint = vault.mountPoint, let problem = Config.problem(withMountPoint: mountPoint) {
                return "\(vault.name): \(problem)"
            }
        }
        let mountPoints = vaults.compactMap(\.expandedMountPoint)
        if Set(mountPoints).count != mountPoints.count { return "Two vaults use the same mount folder" }
        if let name = defaultVault, !vaults.contains(where: { $0.name == name }) { return "Default vault \(name) is not in the list" }
        if autoLock.idleMinutes < 0 { return "Idle minutes can't be negative" }
        return nil
    }

    public static func problem(withMountPoint path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded != "/" else { return "The mount folder must be a full path" }
        if let warning = SyncFolder.warning(for: URL(fileURLWithPath: expanded)) {
            return "The mount folder can't be in a synced folder (plaintext would sync). \(warning)"
        }
        return nil
    }

    public static func problem(withName name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A vault name can't be empty" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "A vault name can't contain control characters"
        }
        return nil
    }

    /// Empty or nil name means the default vault.
    public func vault(named name: String?) -> Vault? {
        let target = (name ?? "").isEmpty ? defaultVault : name
        return vaults.first { $0.name == target }
    }
}

extension Config {
    /// Keys added after 0.1.0 are optional in the file, so older configs keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultVault = try container.decodeIfPresent(String.self, forKey: .defaultVault)
        autoLock = try container.decode(AutoLock.self, forKey: .autoLock)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        vaults = try container.decode([Vault].self, forKey: .vaults)
        raycastScriptsDir = try container.decodeIfPresent(String.self, forKey: .raycastScriptsDir)
        openAfterUnlock = try container.decodeIfPresent(Bool.self, forKey: .openAfterUnlock) ?? false
        panicHotkey = try container.decodeIfPresent(String.self, forKey: .panicHotkey) ?? PanicHotkey.default.id
        panicForces = try container.decodeIfPresent(Bool.self, forKey: .panicForces) ?? true
    }
}
