import Foundation
import Testing
@testable import VaultBarCore

@Suite("Ko-fi support card ask rules")
struct SupportPromptTests {
    private let day = SupportPromptState.day
    private let install = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    private func mayAsk(_ s: SupportPromptState, day d: Double, locks: Int = 50, version: String = "0.5.0") -> Bool {
        s.mayAsk(now: install.addingTimeInterval(d * day), installDate: install, vaultLocks: locks, appVersion: version)
    }

    @Test("first ask needs 7 days and more than 20 vault locks")
    func firstAsk() {
        let s = SupportPromptState()
        #expect(mayAsk(s, day: 6.9) == false)
        #expect(mayAsk(s, day: 30, locks: 20) == false, "never at 20 or fewer, however long installed")
        #expect(mayAsk(s, day: 30, locks: 0) == false)
        #expect(mayAsk(s, day: 7, locks: 21))
    }

    @Test("snooze hides it for 14 days")
    func snooze() {
        var s = SupportPromptState()
        s.record(.snooze, now: install.addingTimeInterval(10 * day), appVersion: "0.5.0")
        #expect(mayAsk(s, day: 23.9) == false)
        #expect(mayAsk(s, day: 24))
    }

    @Test("a tip keeps it quiet for 180 days")
    func tipQuiet() {
        var s = SupportPromptState()
        s.record(.support, now: install.addingTimeInterval(10 * day), appVersion: "0.5.0")
        #expect(mayAsk(s, day: 189) == false)
        #expect(mayAsk(s, day: 190))
    }

    @Test("never lasts until the next major version and 90 days")
    func never() {
        var s = SupportPromptState()
        s.record(.never, now: install.addingTimeInterval(10 * day), appVersion: "0.5.0")
        #expect(mayAsk(s, day: 300, version: "0.9.0") == false, "a feature release must not undo 'never'")
        #expect(mayAsk(s, day: 50, version: "1.0.0") == false, "a major release within 90 days must not undo it")
        #expect(mayAsk(s, day: 100, version: "1.0.0"))
    }

    @Test("at most 3 asks per rolling 365 days")
    func cap() {
        var s = SupportPromptState()
        for d in [10.0, 40, 70] { s.recordShown(install.addingTimeInterval(d * day)) }
        #expect(mayAsk(s, day: 300) == false)
        #expect(mayAsk(s, day: 376), "the first ask has rolled out of the window")
    }

    @Test("old or partial saved state still decodes")
    func oldStateDecodes() throws {
        #expect(try JSONDecoder().decode(SupportPromptState.self, from: Data("{}".utf8)) == SupportPromptState())
        let partial = try JSONDecoder().decode(SupportPromptState.self, from: Data(#"{"snoozedUntil":0,"futureKey":1}"#.utf8))
        #expect(partial.snoozedUntil == Date(timeIntervalSinceReferenceDate: 0), "known keys survive missing and unknown ones")
        #expect(partial.shownAt.isEmpty)
    }
}
