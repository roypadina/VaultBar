import Foundation

/// What exiting now would cut off: a link's unlock prompt, an attach or detach still running, a busy vault waiting
/// for its forced lock, a pause (in memory only), or an open window, menu or alert.
public struct Activity: Sendable {
    public var prompting: Bool
    public var inFlight: Int
    public var pendingForce: Int
    public var paused: Bool
    public var uiOpen: Bool

    public init(prompting: Bool = false, inFlight: Int = 0, pendingForce: Int = 0, paused: Bool = false, uiOpen: Bool = false) {
        self.prompting = prompting
        self.inFlight = inFlight
        self.pendingForce = pendingForce
        self.paused = paused
        self.uiOpen = uiOpen
    }

    public var isIdle: Bool { !prompting && inFlight == 0 && pendingForce == 0 && !paused && !uiOpen }
}

/// Whether a copy started outside launchd may hand off to the login agent now (it exits to let launchd start the
/// supervised copy).
public func canHandOff(isAgent: Bool, handOffDisabled: Bool, launchAtLogin: Bool, agentEnabled: Bool,
                       activity: Activity) -> Bool {
    !isAgent && !handOffDisabled && launchAtLogin && agentEnabled && activity.isIdle
}

/// Whether the bundle on disk is no longer the one running (an upgrade replaced it, or moved it away so its
/// Info.plist can't be read: `onDisk` nil) and it's a good moment to restart into it.
public func shouldRelaunchForUpdate(running: String, onDisk: String?, activity: Activity) -> Bool {
    onDisk != running && activity.isIdle
}

/// `/bin/sh -c` scripts for the detached helper. The app bundle path is passed as `$1`, never spliced in.
public enum HelperScript {
    /// Start the login agent once this copy has exited, and check that the agent itself runs (`launchctl print`
    /// shows its `pid =`): `kickstart` returns 0 even when the spawn then fails. Two tries, 5 s each, then fall back
    /// to opening the app without a hand-off, so VaultBar never ends up not running.
    public static func handOff(uid: UInt32, label: String) -> String {
        let service = "gui/\(uid)/\(label)"
        let wait = "for i in 1 2 3 4 5; do sleep 1; "
            + "/bin/launchctl print \(service) 2>/dev/null | /usr/bin/grep -q '^[[:space:]]*pid = ' && exit 0; done; "
        return "sleep 1; /bin/launchctl kickstart \(service); " + wait
            + "/bin/launchctl kickstart \(service); " + wait
            + #"/usr/bin/open -n "$1" --args --no-handoff"#
    }

    /// After an upgrade: wait (up to a minute) until the new bundle is in place, then open it. That copy refreshes
    /// the login agent registration and hands off. By path, so a moved-away old copy can't be picked; if the
    /// bundle never comes back (the app was moved elsewhere), let LaunchServices find it by bundle id.
    public static func relaunch(waitSeconds: Int = 60) -> String {
        #"sleep 1; for i in $(/usr/bin/seq "# + "\(waitSeconds)"
            + #"); do [ -f "$1/Contents/Info.plist" ] && exec /usr/bin/open -n "$1"; sleep 1; done; "#
            + "exec /usr/bin/open -n -b com.padina.vaultbar"
    }
}
