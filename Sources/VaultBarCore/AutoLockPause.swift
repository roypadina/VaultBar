import Foundation

public enum AutoLockTrigger: Sendable {
    case sleep, screenLock, idle

    /// A busy vault's grace period (30 s screen lock, 60 s idle) just ended: force-detach only if the user
    /// still hasn't come back. Sleep never waits, so it always forces.
    public func shouldForce(screenLocked: Bool, idleSeconds: TimeInterval, idleMinutes: Int, paused: Bool) -> Bool {
        switch self {
        case .sleep: return true
        case .screenLock: return screenLocked && !paused
        case .idle: return !paused && idleMinutes > 0 && idleSeconds >= Double(idleMinutes) * 60
        }
    }
}

/// "Pause auto-lock for 1 hour". In memory only, never saved, so quitting or relaunching ends it.
/// It skips idle and screen-lock auto-lock; the sleep lock always runs.
public struct AutoLockPause: Sendable {
    public static let duration: TimeInterval = 60 * 60
    public private(set) var until: Date?

    public init() {}

    public func isActive(at now: Date = Date()) -> Bool { until.map { now < $0 } ?? false }

    public mutating func start(at now: Date = Date(), duration: TimeInterval = Self.duration) {
        until = now.addingTimeInterval(duration)
    }

    public mutating func resume() { until = nil }

    /// True exactly once, when a pause has run out; it's cleared then.
    public mutating func expire(at now: Date = Date()) -> Bool {
        guard let until, now >= until else { return false }
        self.until = nil
        return true
    }

    public func shouldAutoLock(_ trigger: AutoLockTrigger, settings: AutoLock, idleSeconds: TimeInterval = 0,
                               at now: Date = Date()) -> Bool {
        switch trigger {
        case .sleep:
            return settings.onSleep
        case .screenLock:
            return settings.onScreenLock && !isActive(at: now)
        case .idle:
            return settings.idleMinutes > 0 && idleSeconds >= Double(settings.idleMinutes) * 60 && !isActive(at: now)
        }
    }
}
