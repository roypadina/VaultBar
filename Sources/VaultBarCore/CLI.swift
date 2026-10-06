import Foundation

/// The `vaultbar` command line, on the app's own binary. It never takes a password: `unlock` asks a human in the
/// app's popup. Mutating commands go through `vaultbar://` links, so they work whether or not the app is running.
public enum CLICommand: Equatable, Sendable {
    case status(json: Bool)
    case path(String)
    case lock(String, wait: Int?)
    case lockAll(wait: Int?)
    case unlock(String, readOnly: Bool, wait: Int?)
    case open(String)
    case help
}

public enum CLIExit: Int32 {
    case done = 0, notUnlocked = 1, noSuchVault = 2, timeout = 3, usage = 64
}

public enum CLI {
    public static let subcommands: Set = ["status", "path", "lock", "unlock", "open", "help"]

    public static let usage = """
        usage: vaultbar status [--json]
               vaultbar path [<vault>]
               vaultbar lock [<vault>] [--wait <seconds>]
               vaultbar lock --all [--wait <seconds>]
               vaultbar unlock [<vault>] [--readonly] [--wait <seconds>]
               vaultbar open [<vault>]

        No <vault>: the default vault. unlock asks for the password in VaultBar's popup;
        it never reads one from arguments, the environment or stdin.
        Exit codes: 0 done, 1 locked / not mounted, 2 no such vault, 3 timed out, 64 usage.
        """

    /// nil: not a valid command line (print usage, exit 64).
    public static func parse(_ args: [String]) -> CLICommand? {
        guard let command = args.first else { return nil }
        var name: String?
        var json = false, all = false, readOnly = false
        var wait: Int?
        var rest = args.dropFirst()[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--json" where command == "status": json = true
            case "--all" where command == "lock": all = true
            case "--readonly" where command == "unlock": readOnly = true
            case "--wait" where command == "lock" || command == "unlock":
                guard let value = rest.popFirst().flatMap(Int.init), value >= 0 else { return nil }
                wait = value
            case _ where !arg.hasPrefix("-") && name == nil && command != "status" && command != "help": name = arg
            default: return nil
            }
        }
        switch command {
        case "status": return .status(json: json)
        case "path": return .path(name ?? "")
        case "lock": return all ? (name == nil ? .lockAll(wait: wait) : nil) : .lock(name ?? "", wait: wait)
        case "unlock": return .unlock(name ?? "", readOnly: readOnly, wait: wait)
        case "open": return .open(name ?? "")
        case "help": return .help
        default: return nil
        }
    }
}

public extension CLI {
    /// One line per vault: `Personal (default): unlocked at /Volumes/Personal (read-only)` or `…: locked`.
    static func statusText(_ config: Config, mounted: [String: Mount]) -> String {
        config.vaults.map { vault in
            let mount = mounted.mount(of: vault)
            let state = mount.map { "unlocked at \($0.path)\($0.readOnly ? " (read-only)" : "")" } ?? "locked"
            return "\(vault.name)\(vault.name == config.defaultVault ? " (default)" : ""): \(state)"
        }.joined(separator: "\n")
    }

    /// `{"vaults": [{"name", "default", "unlocked", "hidden", "mountPoint"?, "readOnly"?}]}`, keys sorted.
    static func statusJSON(_ config: Config, mounted: [String: Mount]) -> String {
        let vaults: [[String: Any]] = config.vaults.map { vault in
            let mount = mounted.mount(of: vault)
            var entry: [String: Any] = ["name": vault.name, "default": vault.name == config.defaultVault,
                                        "unlocked": mount != nil, "hidden": vault.isHidden]
            if let mount {
                entry["mountPoint"] = mount.path
                entry["readOnly"] = mount.readOnly
            }
            return entry
        }
        let data = try? JSONSerialization.data(withJSONObject: ["vaults": vaults],
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}
