import Foundation
import Testing

@testable import CallNotesCore

@Suite struct DashboardAnalyticsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_725_969_600) // 2024-09-10 12:00 UTC

    @Test func emptyHistoryProducesNoTotalsOrContacts() {
        let analytics = DashboardAnalytics.make(from: [], now: now, calendar: calendar)

        #expect(analytics.totals.callCount == 0)
        #expect(analytics.totals.totalDurationSec == 0)
        #expect(analytics.totals.metaBilledSeconds == 0)
        #expect(analytics.contacts.isEmpty)
        #expect(analytics.periods.isEmpty)
    }

    @Test func oneMetaCallUsesWholeBilledSecondsForCost() {
        let call = fixtureCall(
            counterparty: "Avery",
            startedAt: now.addingTimeInterval(-600),
            duration: 599,
            engine: .metaMuse,
            billedSeconds: 3_599
        )

        let analytics = DashboardAnalytics.make(from: [call], now: now, calendar: calendar)

        #expect(analytics.totals.callCount == 1)
        #expect(analytics.totals.totalDurationSec == 599)
        #expect(analytics.totals.metaBilledSeconds == 3_599)
        #expect(abs(analytics.totals.metaCostDollars - 0.17995) < 0.000_000_1)
        #expect(abs(analytics.calls[0].costDollars - 0.17995) < 0.000_000_1)
    }

    @Test func groupsRepeatCallersAndUnknownContactsWithTalkTime() {
        let calls = [
            fixtureCall(counterparty: "Avery", startedAt: now.addingTimeInterval(-86_400), duration: 120),
            fixtureCall(counterparty: " Avery ", startedAt: now.addingTimeInterval(-3_600), duration: 180),
            fixtureCall(counterparty: nil, startedAt: now.addingTimeInterval(-1_800), duration: 90),
            fixtureCall(counterparty: "", startedAt: now.addingTimeInterval(-900), duration: 30),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let avery = try! #require(analytics.contacts.first { $0.name == "Avery" })
        let unknown = try! #require(analytics.contacts.first { $0.name == "Unknown" })

        #expect(avery.callCount == 2)
        #expect(avery.totalDurationSec == 300)
        #expect(avery.averageDurationSec == 150)
        #expect(avery.lastContactedAt == now.addingTimeInterval(-3_600))
        #expect(unknown.callCount == 2)
        #expect(unknown.totalDurationSec == 120)
        #expect(unknown.averageDurationSec == 60)
    }

    @Test func manyCallsAggregateDayWeekAndMonthAndKeepDrillDownIDs() {
        let calls = [
            fixtureCall(counterparty: "Avery", startedAt: now.addingTimeInterval(-3_600), duration: 120, engine: .appleSpeech),
            fixtureCall(counterparty: "Mina", startedAt: now.addingTimeInterval(-86_400), duration: 180, engine: .metaMuse, billedSeconds: 60),
            fixtureCall(counterparty: "Jon", startedAt: now.addingTimeInterval(-9 * 86_400), duration: 240, engine: .metaMuse, billedSeconds: 120),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let today = try! #require(analytics.periods.first { $0.range == .day && $0.callCount == 1 })
        let week = try! #require(analytics.periods.first { $0.range == .week && $0.callCount == 2 })
        let month = try! #require(analytics.periods.first { $0.range == .month && $0.callCount == 3 })

        #expect(today.totalDurationSec == 120)
        #expect(today.localCallCount == 1)
        #expect(week.totalDurationSec == 300)
        #expect(week.metaCallCount == 1)
        #expect(month.totalDurationSec == 540)
        #expect(month.metaBilledSeconds == 180)
        #expect(Set(month.callIDs) == Set(calls.map(\.id)))
    }

    @Test func storePublishesAnInsertedCallWithoutARefreshPoll() async throws {
        let store = MemoryStore()
        let changes = await store.dashboardChanges()
        var iterator = changes.makeAsyncIterator()
        let call = fixtureCall(counterparty: "Avery", startedAt: now, duration: 60)

        try await store.upsertCall(call)

        _ = await iterator.next()
        let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
        #expect(snapshot.totals.callCount == 1)
        #expect(snapshot.calls.map(\.id) == [call.id])
    }

    @Test func seededPostgresFixturePreservesContactAndCostTruth() async throws {
        guard let store = await PostgresStore.makeIfAvailable() else { return }
        let fixtureName = "Dashboard fixture \(UUID().uuidString)"
        let calls = [
            fixtureCall(counterparty: fixtureName, startedAt: now.addingTimeInterval(-120), duration: 120),
            fixtureCall(counterparty: fixtureName, startedAt: now.addingTimeInterval(-60), duration: 180, engine: .metaMuse, billedSeconds: 60),
        ]
        for call in calls { try await store.upsertCall(call) }

        let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
        let contact = try #require(snapshot.contacts.first { $0.name == fixtureName })
        let seededCalls = snapshot.calls.filter { Set(calls.map(\.id)).contains($0.id) }

        #expect(contact.callCount == 2)
        #expect(contact.totalDurationSec == 300)
        #expect(seededCalls.reduce(0) { $0 + $1.durationSec } == 300)
        #expect(abs(seededCalls.reduce(0) { $0 + $1.costDollars } - 0.003) < 0.000_000_1)
    }

    private func fixtureCall(
        counterparty: String?,
        startedAt: Date,
        duration: Int,
        engine: STTProviderID = .appleSpeech,
        billedSeconds: Int = 0
    ) -> Call {
        Call(
            source: .macManual,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(TimeInterval(duration)),
            durationSec: duration,
            counterpartyName: counterparty,
            audioPath: "/tmp/dashboard-fixture.caf",
            sttProvider: engine,
            status: .transcribed,
            metaBilledSec: billedSeconds
        )
    }
}
