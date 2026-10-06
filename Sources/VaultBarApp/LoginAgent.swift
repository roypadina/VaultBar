import Foundation
import ServiceManagement
import VaultBarCore

/// The login item: `~/Library/LaunchAgents/<bundle id>.login.plist`, loaded into the user's launchd domain. It runs
/// the app's executable by path, so an upgraded app at the same path starts with nothing to re-register. (0.1.1–0.2.0
/// used an SMAppService agent; launchd pins that one's binary, so after an upgrade it failed with EX_CONFIG.)
/// Blocking calls (`launchctl`): run them off the main thread.
enum LoginAgent {
    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Instance.loginLabel).plist").path
    }
    static var service: String { "gui/\(getuid())/\(Instance.loginLabel)" }

    static func launchctlPrint() -> String? {
        let result = Tool.run("/bin/launchctl", ["print", service])
        return result.ok ? result.stdout : nil
    }

    static var isLoaded: Bool { launchctlPrint() != nil }

    /// Writes the plist for `executable` (if it changed, e.g. the app moved) and loads it. Never called from the
    /// agent copy itself: reloading its own job would stop it. Returns an error message, or nil.
    static func install(executable: String) -> String? {
        let data = LoginAgentPlist.data(label: Instance.loginLabel, executable: executable, bundleID: Instance.bundleID)
        if FileManager.default.contents(atPath: plistPath) != data {
            if isLoaded { _ = Tool.run("/bin/launchctl", ["bootout", service]) }
            do {
                try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            } catch {
                return error.localizedDescription
            }
        }
        if !isLoaded {
            let result = Tool.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
            if !result.ok, !isLoaded { return "launchctl bootstrap: \(result.output)" }
        }
        return nil
    }

    /// Unloads (which stops a copy launchd runs) and deletes the plist.
    static func remove() {
        if isLoaded { _ = Tool.run("/bin/launchctl", ["bootout", service]) }
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// Removes the old SMAppService agent registration, unless this process is that agent's copy (it hands off to
    /// the login agent first; the next copy removes it).
    static func removeSMAppServiceAgent() async {
        guard !Instance.isSMAppServiceCopy else { return }
        let old = SMAppService.agent(plistName: Instance.smAppServiceLabel + ".plist")
        guard old.status == .enabled || old.status == .requiresApproval else { return }
        do {
            try await old.unregister()
            log.notice("removed the old SMAppService login agent")
        } catch {
            log.error("old SMAppService login agent: \(error.localizedDescription, privacy: .public)")
        }
    }
}
