import Foundation

enum QuotaKind: Equatable, Sendable {
    case fiveHour
    case weekly
}

struct QuotaWindow: Equatable, Sendable {
    let kind: QuotaKind
    let remainingPercent: Int
    let resetAt: Date?
    let sourceDurationMins: Int64?
}

struct MappedQuotaWindows: Equatable, Sendable {
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?
}

enum RateLimitMapper {
    private static let fiveHourDuration: Int64 = 300
    private static let weeklyDuration: Int64 = 10_080

    static func map(snapshot: RateLimitSnapshot) -> MappedQuotaWindows {
        let positioned = [(snapshot.primary, true), (snapshot.secondary, false)]

        // Iterating primary first makes duplicate exact-duration windows deterministic.
        let fiveHour = positioned.lazy.compactMap { window, _ in
            exact(window, kind: .fiveHour, duration: fiveHourDuration)
        }.first
        let weekly = positioned.lazy.compactMap { window, _ in
            exact(window, kind: .weekly, duration: weeklyDuration)
        }.first

        // Positional fallback is considered only when both conventional slots
        // exist. Exact-duration candidates always win over their fallback peer;
        // a lone unidentified slot is never guessed.
        if let primary = snapshot.primary, let secondary = snapshot.secondary {
            let fallbackFiveHour = primary.windowDurationMins == nil ? mapped(primary, kind: .fiveHour) : nil
            let fallbackWeekly = secondary.windowDurationMins == nil ? mapped(secondary, kind: .weekly) : nil
            return MappedQuotaWindows(
                fiveHour: fiveHour ?? fallbackFiveHour,
                weekly: weekly ?? fallbackWeekly
            )
        }

        return MappedQuotaWindows(fiveHour: fiveHour, weekly: weekly)
    }

    private static func exact(_ window: RateLimitWindow?, kind: QuotaKind, duration: Int64) -> QuotaWindow? {
        guard let window, window.windowDurationMins == duration else { return nil }
        return mapped(window, kind: kind)
    }

    private static func mapped(_ window: RateLimitWindow, kind: QuotaKind) -> QuotaWindow {
        let clampedUsedPercent = min(100, max(0, window.usedPercent))
        return QuotaWindow(
            kind: kind,
            remainingPercent: 100 - clampedUsedPercent,
            resetAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            sourceDurationMins: window.windowDurationMins
        )
    }
}
