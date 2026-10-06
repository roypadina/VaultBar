import Foundation

public enum VaultAction: String, Sendable {
    case unlock, lock, toggle, open
    /// `vaultbar://lockall`: no vault name.
    case lockAll = "lockall"
}

public struct VaultRequest: Equatable, Sendable {
    public var action: VaultAction
    /// Decoded; "" means the default vault.
    public var name: String
    /// `?readonly=1` / `?readonly=0`; nil: the vault's own setting.
    public var readOnly: Bool?

    public init(action: VaultAction, name: String, readOnly: Bool? = nil) {
        self.action = action
        self.name = name
        self.readOnly = readOnly
    }
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
        case (.lock, true), (.toggle, true), (.lockAll, true): .lock
        case (.lockAll, false): .nothing
        case (.open, true): .openInFinder
        case (.open, false): .promptUnlock(thenOpen: true)
        case (.unlock, false), (.toggle, false): .promptUnlock(thenOpen: openAfterUnlock)
        }
    }
}

public enum VaultURL {
    public static let scheme = "vaultbar"

    /// `vaultbar://<action>/<url-encoded name>[?readonly=1]`.
    public static func parse(_ url: URL) -> VaultRequest? {
        guard url.scheme?.lowercased() == scheme,
              let action = url.host.flatMap({ VaultAction(rawValue: $0.lowercased()) }) else { return nil }
        let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let readOnly = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "readonly" }?.value.map { ["1", "true", "yes"].contains($0.lowercased()) }
        return VaultRequest(action: action, name: name, readOnly: readOnly)
    }

    public static func make(_ action: VaultAction, name: String, readOnly: Bool? = nil) -> String {
        "\(scheme)://\(action.rawValue)/\(name.addingPercentEncoding(withAllowedCharacters: unreserved)!)"
            + (readOnly.map { "?readonly=\($0 ? 1 : 0)" } ?? "")
    }

    /// ASCII only, so the URL is safe to drop inside double quotes in a shell script.
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// What a click on the menu bar icon does.
public enum StatusClick: Equatable, Sendable {
    case toggleDefault, menu, lockAll

    /// Right-click or Control-click: the menu. ⌥-click: Lock All. A plain click toggles the default vault (the menu
    /// when there is none).
    public static func action(rightButton: Bool, control: Bool, option: Bool, hasDefault: Bool) -> StatusClick {
        if rightButton || control { return .menu }
        if option { return .lockAll }
        return hasDefault ? .toggleDefault : .menu
    }
}
