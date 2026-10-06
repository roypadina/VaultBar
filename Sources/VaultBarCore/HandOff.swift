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

/// Whether a newer bundle has replaced the one running and it's a good moment to start it. A bundle that can't be
/// read (`onDisk` nil: an upgrade is moving it) is waited for, never "relaunched" into nothing.
public func shouldRelaunchForUpdate(running: String, onDisk: String?, activity: Activity) -> Bool {
    guard let onDisk else { return false }
    return onDisk != running && activity.isIdle
}

/// Zero-gap succession between two copies of the app: at every moment at least one copy runs. The copy that is
/// leaving (the predecessor) writes a marker naming itself and starts its successor; the successor acknowledges and
/// waits for the predecessor to exit, instead of quitting as a second copy would; the predecessor exits only once
/// that acknowledgement exists and its writer is alive.
public enum Succession {
    public struct Marker: Equatable, Sendable {
        public let pid: Int32
        public let date: Date
    }

    public struct Ack: Equatable, Sendable {
        public let successor: Int32
        public let predecessor: Int32
    }

    /// A successor ignores markers older than this.
    public static let markerLifetime: TimeInterval = 90
    /// How long a successor waits for its predecessor to exit before giving up (it then exits, the predecessor stays).
    public static let successorWait: TimeInterval = 15
    /// Hand-off to the login agent: when to (re)ask launchd to start it, and when to give up and stay.
    public static let handOffKickstarts: [TimeInterval] = [0, 5, 10, 15]
    public static let handOffTimeout: TimeInterval = 20
    /// Update: how long the old copy waits for the new one to acknowledge.
    public static let updateTimeout: TimeInterval = 60

    public static func markerText(pid: Int32, date: Date) -> String { "\(pid) \(date.timeIntervalSince1970)" }

    public static func parseMarker(_ text: String) -> Marker? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let pid = Int32(parts[0]), let time = Double(parts[1]) else { return nil }
        return Marker(pid: pid, date: Date(timeIntervalSince1970: time))
    }

    public static func ackText(successor: Int32, predecessor: Int32) -> String { "\(successor) \(predecessor)" }

    public static func parseAck(_ text: String) -> Ack? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let successor = Int32(parts[0]), let predecessor = Int32(parts[1]) else { return nil }
        return Ack(successor: successor, predecessor: predecessor)
    }

    /// Successor at launch, finding another copy: wait for it (instead of exiting) when a fresh marker names it and
    /// it is alive. `rivalPID` nil: only the instance lock says a copy runs.
    public static func shouldWait(for marker: Marker?, markerPIDAlive: Bool, rivalPID: Int32?, now: Date) -> Bool {
        guard let marker, markerPIDAlive, now.timeIntervalSince(marker.date) < markerLifetime else { return false }
        return rivalPID == nil || rivalPID == marker.pid
    }

    /// Predecessor: exit only once its own successor has acknowledged, is alive, and nothing is in progress here.
    public static func mayExit(ack: Ack?, myPID: Int32, successorAlive: Bool, activity: Activity) -> Bool {
        guard let ack, ack.predecessor == myPID, ack.successor != myPID, successorAlive else { return false }
        return activity.isIdle
    }
}

/// The login item: a classic LaunchAgent (`~/Library/LaunchAgents/<label>.plist`) that runs the app's executable
/// by path. launchd restarts it after a crash (not after Quit, exit 0). Unlike an SMAppService agent, nothing pins
/// the binary, so an upgraded app at the same path starts without re-registering.
public enum LoginAgentPlist {
    public static func data(label: String, executable: String, bundleID: String) -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "AssociatedBundleIdentifiers": [bundleID],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    /// The executable an existing plist runs (nil: unreadable).
    public static func program(in data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (plist?["ProgramArguments"] as? [String])?.first
    }
}

/// From `launchctl print gui/<uid>/<label>`.
public enum LaunchdJob {
    /// The pid of the job's running process, if any.
    public static func runningPID(launchctlPrint output: String?) -> Int32? {
        output.flatMap { value("pid", in: $0) }.flatMap { Int32($0) }
    }

    static func value(_ key: String, in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + " = ") { return String(trimmed.dropFirst(key.count + 3)) }
        }
        return nil
    }
}
