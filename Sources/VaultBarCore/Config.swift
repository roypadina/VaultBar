import Foundation

public struct Vault: Codable, Equatable, Sendable {
    public var name: String
    /// May start with `~`; stored as the user typed or picked it.
    public var imagePath: String

    public init(name: String, imagePath: String) {
        self.name = name
        self.imagePath = imagePath
    }

    public var expandedPath: String { NSString(string: imagePath).expandingTildeInPath }
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

    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vaultbar/vaults.json")

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
        }
        if let name = defaultVault, !vaults.contains(where: { $0.name == name }) { return "Default vault \(name) is not in the list" }
        if autoLock.idleMinutes < 0 { return "Idle minutes can't be negative" }
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
    }
}
