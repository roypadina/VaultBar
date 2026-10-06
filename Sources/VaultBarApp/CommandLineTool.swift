import Foundation
import VaultBarCore

/// `vaultbar …` (the cask links it into the PATH). Never starts the app's UI and never takes a password: unlocking
/// still means a human typing into VaultBar's popup. Mutating commands send `vaultbar://` links via `open -g`,
/// which also starts VaultBar if it isn't running.
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Int32 {
        guard let command = CLI.parse(arguments) else {
            printError(CLI.usage)
            return CLIExit.usage.rawValue
        }
        if command == .help {
            print(CLI.usage)
            return CLIExit.done.rawValue
        }
        let config: Config
        do {
            config = try Config.load() ?? Config.seed
        } catch {
            printError("vaultbar: can't read \(Config.url.path): \(error.localizedDescription)")
            return CLIExit.notUnlocked.rawValue
        }
        func vault(_ name: String) -> Vault? {
            if let vault = config.vault(named: name) { return vault }
            printError(name.isEmpty ? "vaultbar: no default vault is set" : "vaultbar: no vault named \"\(name)\"")
            return nil
        }
        switch command {
        case .help:
            return CLIExit.done.rawValue
        case .status(let json):
            status(config, json: json)
            return CLIExit.done.rawValue
        case .path(let name):
            guard let vault = vault(name) else { return CLIExit.noSuchVault.rawValue }
            guard let path = HDIUtil.mounted().mountPoint(of: vault) else {
                printError("vaultbar: \(vault.name) is locked")
                return CLIExit.notUnlocked.rawValue
            }
            print(path)
            return CLIExit.done.rawValue
        case .lock(let name, let wait):
            guard let vault = vault(name) else { return CLIExit.noSuchVault.rawValue }
            if HDIUtil.mounted().mountPoint(of: vault) == nil { return CLIExit.done.rawValue }
            guard send(VaultURL.make(.lock, name: vault.name)) else { return CLIExit.notUnlocked.rawValue }
            return waitUntil(wait) { HDIUtil.mounted().mountPoint(of: vault) == nil }
        case .lockAll(let wait):
            guard send("\(VaultURL.scheme)://\(VaultAction.lockAll.rawValue)") else { return CLIExit.notUnlocked.rawValue }
            return waitUntil(wait) { let mounted = HDIUtil.mounted(); return config.vaults.allSatisfy { mounted.mountPoint(of: $0) == nil } }
        case .unlock(let name, let readOnly, let wait):
            guard let vault = vault(name) else { return CLIExit.noSuchVault.rawValue }
            if let path = HDIUtil.mounted().mountPoint(of: vault) {
                print(path)
                return CLIExit.done.rawValue
            }
            guard send(VaultURL.make(.unlock, name: vault.name, readOnly: readOnly ? true : nil)) else {
                return CLIExit.notUnlocked.rawValue
            }
            let code = waitUntil(wait) { HDIUtil.mounted().mountPoint(of: vault) != nil }
            if wait != nil, code == CLIExit.done.rawValue, let path = HDIUtil.mounted().mountPoint(of: vault) { print(path) }
            return code
        case .open(let name):
            guard let vault = vault(name) else { return CLIExit.noSuchVault.rawValue }
            return send(VaultURL.make(.open, name: vault.name)) ? CLIExit.done.rawValue : CLIExit.notUnlocked.rawValue
        }
    }

    private static func status(_ config: Config, json: Bool) {
        let mounted = HDIUtil.mounted()
        let text = json ? CLI.statusJSON(config, mounted: mounted) : CLI.statusText(config, mounted: mounted)
        if !text.isEmpty { print(text) }
    }

    /// `open -g`: the app doesn't come to the front (the password popup takes the keyboard on its own).
    private static func send(_ url: String) -> Bool {
        let result = Tool.run("/usr/bin/open", ["-g", url])
        if !result.ok { printError("vaultbar: couldn't reach VaultBar: \(result.output)") }
        return result.ok
    }

    /// No `--wait`: done as soon as the request is sent. Otherwise poll once a second.
    private static func waitUntil(_ seconds: Int?, _ done: () -> Bool) -> Int32 {
        guard let seconds else { return CLIExit.done.rawValue }
        for _ in 0..<seconds where !done() { sleep(1) }
        return done() ? CLIExit.done.rawValue : CLIExit.timeout.rawValue
    }

    static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
