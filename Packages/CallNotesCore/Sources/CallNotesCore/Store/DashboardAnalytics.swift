import Foundation

/// The time grain used to group call activity in the dashboard.
public enum DashboardPeriodRange: String, CaseIterable, Codable, Sendable {
    case day
    case week
    case month
}

public enum DashboardEngine: String, Sendable, Equatable {
    case local
    case meta
    case mixed

    public var displayName: String {
        rawValue.capitalized
    }
}

/// A call enriched with presentation-neutral analytics values.
public struct DashboardCall: Identifiable, Sendable, Equatable {
    public let call: Call
    public let durationSec: Int
    public let costDollars: Double

    public var id: UUID { call.id }
    public var counterpartyName: String { DashboardAnalytics.contactName(for: call.counterpartyName) }
    public var engine: DashboardEngine {
        let providers = call.transcriptionProviders + [call.sttProvider]
        let usesMeta = call.metaBilledSec > 0 || providers.contains(.metaMuse)
        let usesLocal = providers.contains { $0 != .metaMuse }
        if usesMeta && usesLocal { return .mixed }
        return usesMeta ? .meta : .local
    }

    init(call: Call, durationSec: Int) {
        self.call = call
        self.durationSec = durationSec
        self.costDollars = MetaCostMeter.costDollars(billedSeconds: max(0, call.metaBilledSec))
    }
}

public struct DashboardTotals: Sendable, Equatable {
    public let callCount: Int
    public let localCallCount: Int
    public let metaCallCount: Int
    public let mixedCallCount: Int
    public let totalDurationSec: Int
    public let metaBilledSeconds: Int
    public let metaCostDollars: Double
}

public struct DashboardPeriod: Identifiable, Sendable, Equatable {
    public let range: DashboardPeriodRange
    public let startsAt: Date
    public let callCount: Int
    public let localCallCount: Int
    public let metaCallCount: Int
    public let mixedCallCount: Int
    public let totalDurationSec: Int
    public let metaBilledSeconds: Int
    public let metaCostDollars: Double
    public let callIDs: [UUID]

    public var id: String { "\(range.rawValue)-\(startsAt.timeIntervalSinceReferenceDate)" }
}

public struct DashboardContact: Identifiable, Sendable, Equatable {
    public let name: String
    public let callCount: Int
    public let totalDurationSec: Int
    public let averageDurationSec: Int
    public let lastContactedAt: Date
    public let callIDs: [UUID]

    public var id: String { name }
}

/// Store-owned snapshot used by the dashboard. Views only render this value.
public struct DashboardAnalytics: Sendable, Equatable {
    public let generatedAt: Date
    public let calls: [DashboardCall]
    public let totals: DashboardTotals
    public let periods: [DashboardPeriod]
    public let contacts: [DashboardContact]

    public static func make(
        from calls: [Call],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DashboardAnalytics {
        let dashboardCalls = calls
            .map { DashboardCall(call: $0, durationSec: duration(for: $0, now: now)) }
            .sorted { $0.call.startedAt > $1.call.startedAt }
        let totals = totals(for: dashboardCalls)
        let groupedPeriods = DashboardPeriodRange.allCases.flatMap { range in
            periods(for: dashboardCalls, range: range, calendar: calendar)
        }
        let groupedContacts = contacts(for: dashboardCalls)
        return DashboardAnalytics(
            generatedAt: now,
            calls: dashboardCalls,
            totals: totals,
            periods: groupedPeriods,
            contacts: groupedContacts
        )
    }

    public static func contactName(for name: String?) -> String {
        guard let name else { return "Unknown" }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private static func duration(for call: Call, now: Date) -> Int {
        if let duration = call.durationSec { return max(0, duration) }
        let end = call.endedAt ?? now
        return max(0, Int(end.timeIntervalSince(call.startedAt).rounded(.down)))
    }

    private static func totals(for calls: [DashboardCall]) -> DashboardTotals {
        DashboardTotals(
            callCount: calls.count,
            localCallCount: calls.count(where: { $0.engine == .local }),
            metaCallCount: calls.count(where: { $0.engine == .meta }),
            mixedCallCount: calls.count(where: { $0.engine == .mixed }),
            totalDurationSec: calls.reduce(0) { $0 + $1.durationSec },
            metaBilledSeconds: calls.reduce(0) { $0 + max(0, $1.call.metaBilledSec) },
            metaCostDollars: calls.reduce(0) { $0 + $1.costDollars }
        )
    }

    private static func periods(
        for calls: [DashboardCall],
        range: DashboardPeriodRange,
        calendar: Calendar
    ) -> [DashboardPeriod] {
        let grouped = Dictionary(grouping: calls) { call in
            periodStart(for: call.call.startedAt, range: range, calendar: calendar)
        }
        return grouped.map { startsAt, calls in
            let totals = totals(for: calls)
            return DashboardPeriod(
                range: range,
                startsAt: startsAt,
                callCount: totals.callCount,
                localCallCount: totals.localCallCount,
                metaCallCount: totals.metaCallCount,
                mixedCallCount: totals.mixedCallCount,
                totalDurationSec: totals.totalDurationSec,
                metaBilledSeconds: totals.metaBilledSeconds,
                metaCostDollars: totals.metaCostDollars,
                callIDs: calls.map(\.id)
            )
        }
        .sorted { $0.startsAt > $1.startsAt }
    }

    private static func contacts(for calls: [DashboardCall]) -> [DashboardContact] {
        Dictionary(grouping: calls) { $0.counterpartyName }
            .map { name, calls in
                let totalDuration = calls.reduce(0) { $0 + $1.durationSec }
                return DashboardContact(
                    name: name,
                    callCount: calls.count,
                    totalDurationSec: totalDuration,
                    averageDurationSec: totalDuration / calls.count,
                    lastContactedAt: calls.map(\.call.startedAt).max()!,
                    callIDs: calls.sorted { $0.call.startedAt > $1.call.startedAt }.map(\.id)
                )
            }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                return $0.lastContactedAt > $1.lastContactedAt
            }
    }

    private static func periodStart(
        for date: Date,
        range: DashboardPeriodRange,
        calendar: Calendar
    ) -> Date {
        switch range {
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}
