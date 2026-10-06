import Foundation

public enum PasswordAdvice {
    /// Warnings (not errors) for a new vault password.
    public static func warnings(for password: String, names: [String]) -> [String] {
        var result: [String] = []
        if password.count < 12 { result.append("It's shorter than 12 characters.") }
        let lowered = password.lowercased()
        if names.contains(where: { $0.count >= 3 && lowered.contains($0.lowercased()) }) {
            result.append("It contains the vault's name.")
        }
        return result
    }
}
