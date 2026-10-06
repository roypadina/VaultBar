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
    /// Start the login agent once this copy has exited, then make sure some VaultBar runs: `kickstart` returns 0
    /// even when the spawn then fails, so check for the process and fall back to opening the app without a hand-off.
    public static func handOff(uid: UInt32, label: String) -> String {
        "sleep 1; /bin/launchctl kickstart gui/\(uid)/\(label); "
            + "for i in 1 2 3 4 5; do sleep 1; /usr/bin/pgrep -x -U \(uid) VaultBar >/dev/null && exit 0; done; "
            + #"/usr/bin/open -n "$1" --args --no-handoff"#
    }

    /// After an upgrade: wait (up to a minute) until the new bundle is in place, then open it. That copy refreshes
    /// the login agent registration and hands off. By path, so a moved-away old copy can't be picked.
    public static func relaunch() -> String {
        #"sleep 1; for i in $(/usr/bin/seq 60); do [ -f "$1/Contents/Info.plist" ] && break; sleep 1; done; "#
            + #"/usr/bin/open -n "$1""#
    }
}
