import Foundation

public enum VaultAction: String, Sendable {
    case unlock, lock, toggle
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
