import Foundation
import Testing
@testable import QuotaOverlayApp

@Suite("Rate limit mapper")
struct RateLimitMapperTests {
    @Test("exact durations identify windows regardless of position")
    func exactDurationsInReversedPositions() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 20, duration: 10_080),
            secondary: window(used: 90, duration: 300)
        ))

        #expect(result.fiveHour == QuotaWindow(kind: .fiveHour, remainingPercent: 10, resetAt: nil, sourceDurationMins: 300))
        #expect(result.weekly == QuotaWindow(kind: .weekly, remainingPercent: 80, resetAt: nil, sourceDurationMins: 10_080))
    }

    @Test("one exact window maps independently")
    func oneWindow() {
        let result = RateLimitMapper.map(snapshot: snapshot(primary: window(used: 20, duration: 10_080)))
        #expect(result.fiveHour == nil)
        #expect(result.weekly?.remainingPercent == 80)
    }

    @Test("unknown durations are ignored")
    func unknownDurations() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 20, duration: 60),
            secondary: window(used: 30, duration: 1_440)
        ))
        #expect(result == MappedQuotaWindows(fiveHour: nil, weekly: nil))
    }

    @Test("two unidentified positional windows use conservative fallback")
    func unambiguousFallback() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 20), secondary: window(used: 30)
        ))
        #expect(result.fiveHour?.kind == .fiveHour)
        #expect(result.fiveHour?.sourceDurationMins == nil)
        #expect(result.weekly?.kind == .weekly)
        #expect(result.weekly?.sourceDurationMins == nil)
    }

    @Test("a single unidentified window is never guessed", arguments: [true, false])
    func ambiguousFallback(primary: Bool) {
        let unidentified = window(used: 20)
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: primary ? unidentified : nil,
            secondary: primary ? nil : unidentified
        ))
        #expect(result == MappedQuotaWindows(fiveHour: nil, weekly: nil))
    }

    @Test("exact identification beats fallback candidates")
    func exactBeatsFallback() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 20), secondary: window(used: 90, duration: 300)
        ))
        #expect(result.fiveHour?.remainingPercent == 10)
        #expect(result.weekly == nil)
    }

    @Test("fallback can supply the kind missing from an exact window")
    func fallbackSuppliesMissingKind() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 20, duration: 300), secondary: window(used: 30)
        ))
        #expect(result.fiveHour?.remainingPercent == 80)
        #expect(result.weekly?.remainingPercent == 70)
    }

    @Test("duplicate exact kinds prefer primary")
    func duplicateExactPrefersPrimary() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 20, duration: 300),
            secondary: window(used: 90, duration: 300)
        ))
        #expect(result.fiveHour?.remainingPercent == 80)
    }

    @Test("remaining percentage is clamped", arguments: [
        (0, 100), (20, 80), (90, 10), (100, 0), (-10, 100), (Int.min, 100), (120, 0)
    ])
    func percentageClamping(used: Int, remaining: Int) {
        let result = RateLimitMapper.map(snapshot: snapshot(primary: window(used: used, duration: 300)))
        #expect(result.fiveHour?.remainingPercent == remaining)
    }

    @Test("Unix reset seconds become Date and nil stays nil")
    func resetConversion() {
        let result = RateLimitMapper.map(snapshot: snapshot(
            primary: window(used: 0, reset: 1_735_689_600, duration: 300),
            secondary: window(used: 0, duration: 10_080)
        ))
        #expect(result.fiveHour?.resetAt == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(result.weekly?.resetAt == nil)
    }

    private func snapshot(primary: RateLimitWindow? = nil, secondary: RateLimitWindow? = nil) -> RateLimitSnapshot {
        RateLimitSnapshot(credits: nil, limitId: nil, limitName: nil, planType: nil, primary: primary,
                          rateLimitReachedType: nil, secondary: secondary)
    }

    private func window(used: Int, reset: Int64? = nil, duration: Int64? = nil) -> RateLimitWindow {
        RateLimitWindow(usedPercent: used, resetsAt: reset, windowDurationMins: duration)
    }
}
