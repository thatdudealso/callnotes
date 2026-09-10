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
    public let counterpartyName: String
    public let engine: DashboardEngine

    /// A call left mid-processing by a crash has no end and no duration. Crash
    /// recovery is Phase 7, so until then it contributes no talk time and says so
    /// rather than growing a total nobody can trace.
    public let isIncomplete: Bool

    public var id: UUID { call.id }

    init(call: Call, durationSec: Int, counterpartyName: String) {
        self.call = call
        self.durationSec = durationSec
        self.costDollars = MetaCostMeter.costDollars(billedSeconds: max(0, call.metaBilledSec))
        self.counterpartyName = counterpartyName
        self.engine = Self.engine(for: call)
        self.isIncomplete = DashboardAnalytics.isIncomplete(call)
    }

    private static func engine(for call: Call) -> DashboardEngine {
        let usesMeta = call.metaBilledSec > 0
            || call.sttProvider == .metaMuse
            || call.transcriptionProviders.contains(.metaMuse)
        let usesLocal = call.sttProvider != .metaMuse
            || call.transcriptionProviders.contains { $0 != .metaMuse }
        if usesMeta && usesLocal { return .mixed }
        return usesMeta ? .meta : .local
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
    public let incompleteCallCount: Int
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

    /// `counterpartyNames` supplies the identity fallback for calls that carry no
    /// user-edited name. A call's own name always wins, so a stale or store-side
    /// entry can never override what the user typed. `contacts` lets a store hand
    /// over an aggregation it computed itself; when omitted the Swift grouping
    /// below is the reference implementation.
    public static func make(
        from calls: [Call],
        counterpartyNames: [UUID: String] = [:],
        contacts: [DashboardContact]? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DashboardAnalytics {
        let dashboardCalls = calls
            .map {
                DashboardCall(
                    call: $0,
                    durationSec: duration(for: $0, now: now),
                    counterpartyName: contactName(for: $0.counterpartyName, fallback: counterpartyNames[$0.id])
                )
            }
            .sorted { $0.call.startedAt > $1.call.startedAt }
        let totals = totals(for: dashboardCalls)
        let groupedPeriods = DashboardPeriodRange.allCases.flatMap { range in
            periods(for: dashboardCalls, range: range, calendar: calendar)
        }
        return DashboardAnalytics(
            generatedAt: now,
            calls: dashboardCalls,
            totals: totals,
            periods: groupedPeriods,
            contacts: contacts ?? self.contacts(for: dashboardCalls)
        )
    }

    public static func contactName(for name: String?, fallback: String? = nil) -> String {
        if let resolved = normalized(name) { return resolved }
        return normalized(fallback) ?? "Unknown"
    }

    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Only a call that is still recording may extrapolate to now; every other
    /// open-ended row would otherwise grow its own duration forever.
    static let incompleteProcessingStatuses: Set<CallStatus> = [.uploaded, .transcribing]

    static func isIncomplete(_ call: Call) -> Bool {
        call.durationSec == nil
            && call.endedAt == nil
            && incompleteProcessingStatuses.contains(call.status)
    }

    private static func duration(for call: Call, now: Date) -> Int {
        if let duration = call.durationSec { return max(0, duration) }
        if let endedAt = call.endedAt {
            return max(0, Int(endedAt.timeIntervalSince(call.startedAt).rounded(.down)))
        }
        guard call.status == .recording else { return 0 }
        return max(0, Int(now.timeIntervalSince(call.startedAt).rounded(.down)))
    }

    private static func totals(for calls: [DashboardCall]) -> DashboardTotals {
        DashboardTotals(
            callCount: calls.count,
            localCallCount: calls.count(where: { $0.engine == .local }),
            metaCallCount: calls.count(where: { $0.engine == .meta }),
            mixedCallCount: calls.count(where: { $0.engine == .mixed }),
            totalDurationSec: calls.reduce(0) { $0 + $1.durationSec },
            metaBilledSeconds: calls.reduce(0) { $0 + max(0, $1.call.metaBilledSec) },
            metaCostDollars: calls.reduce(0) { $0 + $1.costDollars },
            incompleteCallCount: calls.count(where: \.isIncomplete)
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
        Dictionary(grouping: calls) { contactIdentity(for: $0) }
            .map { _, calls in
                let sortedCalls = calls.sorted { $0.call.startedAt > $1.call.startedAt }
                let totalDuration = calls.reduce(0) { $0 + $1.durationSec }
                let timedCalls = calls.count { !$0.isIncomplete }
                return DashboardContact(
                    name: sortedCalls[0].counterpartyName,
                    callCount: calls.count,
                    totalDurationSec: totalDuration,
                    averageDurationSec: totalDuration / max(1, timedCalls),
                    lastContactedAt: calls.map(\.call.startedAt).max()!,
                    callIDs: sortedCalls.map(\.id)
                )
            }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                return $0.lastContactedAt > $1.lastContactedAt
            }
    }

    private static func contactIdentity(for call: DashboardCall) -> String {
        call.counterpartyName.lowercased()
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
