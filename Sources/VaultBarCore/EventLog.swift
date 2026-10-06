import Foundation

/// The last few lock/unlock events, in memory only (never written to disk).
public struct EventLog: Sendable {
    public struct Event: Equatable, Sendable {
        public let date: Date
        public let text: String
    }

    public private(set) var events: [Event] = []
    public let capacity: Int

    public init(capacity: Int = 50) { self.capacity = capacity }

    public mutating func add(_ text: String, at date: Date = Date()) {
        events.append(Event(date: date, text: text))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public var last: Event? { events.last }
}
