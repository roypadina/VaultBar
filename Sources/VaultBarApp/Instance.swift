import Foundation

/// Names derived from the bundle id, so a differently-identified build (the launchd test variant) never shares the
/// real app's lock, hand-off files or login agent.
enum Instance {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.padina.vaultbar"
    /// The login agent's launchd label (see `LoginAgent`).
    static let loginLabel = bundleID + ".login"
    /// The SMAppService agent of 0.1.1–0.2.0, replaced by the login agent.
    static let smAppServiceLabel = bundleID + ".agent"
    /// launchd sets XPC_SERVICE_NAME to the job label in the copy it starts.
    static let isAgentCopy = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == loginLabel
    static let isSMAppServiceCopy = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == smAppServiceLabel
    /// Info.plist `VBHeadless` (test variant only): no menu bar item, notifications or hotkey.
    static let isHeadless = Bundle.main.object(forInfoDictionaryKey: "VBHeadless") as? Bool == true

    static func path(_ name: String) -> String { NSTemporaryDirectory() + "\(bundleID).\(name)" }
    static func read(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }
    static func write(_ name: String, _ text: String) { try? text.write(toFile: path(name), atomically: true, encoding: .utf8) }
    static func remove(_ name: String) { try? FileManager.default.removeItem(atPath: path(name)) }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
