import Foundation

/// Three Raycast Script Commands per vault (unlock, lock, open). They only `open vaultbar://...`; the app asks for the
/// password, so it never passes through Raycast.
public enum Raycast {
    /// Marks files VaultBar wrote; only those are ever deleted.
    static let marker = "# @raycast.packageName VaultBar"

    public static func slug(_ name: String) -> String {
        let mapped = name.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }
        let slug = String(mapped).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "vault" : slug
    }

    /// File name -> script contents.
    public static func scripts(for vaults: [Vault]) -> [String: String] {
        var result: [String: String] = [:]
        for vault in vaults {
            for (action, verb, icon) in [(VaultAction.unlock, "Unlock", "🔓"), (.lock, "Lock", "🔒"), (.open, "Open", "📂")] {
                result["vaultbar-\(action.rawValue)-\(slug(vault.name)).sh"] = """
                    #!/bin/bash

                    # @raycast.schemaVersion 1
                    # @raycast.title \(verb) \(vault.name)
                    # @raycast.mode silent
                    \(marker)
                    # @raycast.icon \(icon)
                    # @raycast.description \(verb) the \(vault.name) vault with VaultBar\(descriptionSuffix[action] ?? "")

                    open "\(VaultURL.make(action, name: vault.name))"

                    """
            }
        }
        return result
    }

    static let descriptionSuffix: [VaultAction: String] = [
        .unlock: " (it asks for the password)",
        .open: " in Finder (unlocks it first if needed)",
    ]

    /// Writes the scripts for `vaults` and removes VaultBar-written scripts of vaults no longer configured.
    /// Never touches any other file in `directory`.
    public static func sync(_ vaults: [Vault], in directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let wanted = scripts(for: vaults)
        for (name, body) in wanted {
            let url = directory.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) == body { continue } // runs on every launch
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for name in try fm.contentsOfDirectory(atPath: directory.path)
        where name.hasPrefix("vaultbar-") && name.hasSuffix(".sh") && wanted[name] == nil {
            let url = directory.appendingPathComponent(name)
            if let body = try? String(contentsOf: url, encoding: .utf8), body.contains(marker + "\n") {
                try fm.removeItem(at: url)
            }
        }
    }
}
