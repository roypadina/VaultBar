import Foundation

public enum VaultAction: String, Sendable {
    case unlock, lock, toggle, open
}

/// What an action does to a vault in its current state.
public enum VaultStep: Equatable, Sendable {
    case nothing
    case lock
    case openInFinder
    /// Show the password popup; `thenOpen`: open the vault in Finder after a successful unlock.
    case promptUnlock(thenOpen: Bool)
}

public extension VaultAction {
    /// `openAfterUnlock` (the setting) applies to unlock and toggle; `open` always opens.
    /// Unlock on an unlocked vault and lock on a locked one do nothing.
    func step(unlocked: Bool, openAfterUnlock: Bool) -> VaultStep {
        switch (self, unlocked) {
        case (.unlock, true), (.lock, false): .nothing
        case (.lock, true), (.toggle, true): .lock
        case (.open, true): .openInFinder
        case (.open, false): .promptUnlock(thenOpen: true)
        case (.unlock, false), (.toggle, false): .promptUnlock(thenOpen: openAfterUnlock)
        }
    }
}

public enum VaultURL {
    public static let scheme = "vaultbar"

    /// `vaultbar://<action>/<url-encoded name>`. The name comes back decoded; "" means the default vault.
    public static func parse(_ url: URL) -> (action: VaultAction, name: String)? {
        guard url.scheme?.lowercased() == scheme,
              let action = url.host.flatMap({ VaultAction(rawValue: $0.lowercased()) }) else { return nil }
        let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (action, name)
    }

    public static func make(_ action: VaultAction, name: String) -> String {
        "\(scheme)://\(action.rawValue)/\(name.addingPercentEncoding(withAllowedCharacters: unreserved)!)"
    }

    /// ASCII only, so the URL is safe to drop inside double quotes in a shell script.
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
