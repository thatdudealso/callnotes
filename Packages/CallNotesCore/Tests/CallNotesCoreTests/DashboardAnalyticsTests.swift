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

    @Test func groupsCounterpartyNamesCaseInsensitivelyRegardlessOfNumber() {
        let calls = [
            fixtureCall(
                counterparty: "Alex",
                number: "+15550000001",
                startedAt: now.addingTimeInterval(-60),
                duration: 120
            ),
            fixtureCall(
                counterparty: "alex",
                number: "+15550000002",
                startedAt: now.addingTimeInterval(-120),
                duration: 180
            ),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let alex = try! #require(analytics.contacts.first { $0.name == "Alex" })

        #expect(analytics.contacts.count == 1)
        #expect(alex.callCount == 2)
        #expect(alex.totalDurationSec == 300)
        #expect(Set(alex.callIDs) == Set(calls.map(\.id)))
    }

    @Test func resolvesMatchedProfileWhenNoCounterpartyNameIsPresent() async throws {
        let store = MemoryStore()
        let call = fixtureCall(counterparty: nil, startedAt: now, duration: 60)
        let profile = SpeakerProfile(
            displayName: "Avery",
            centroid: [0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertCall(call)
        try await store.upsertSpeakerProfile(profile)
        try await store.replaceCallSpeakers(
            callID: call.id,
            speakers: [CallSpeaker(callID: call.id, clusterKey: "far", profileID: profile.id, confidence: 0.9)]
        )

        let analytics = try await store.fetchDashboardAnalytics(asOf: now)

        #expect(analytics.calls[0].counterpartyName == "Avery")
        #expect(analytics.contacts.map(\.name) == ["Avery"])
    }

    @Test func editedCounterpartyNameOverridesMatchedProfile() async throws {
        let store = MemoryStore()
        let call = fixtureCall(counterparty: "Morgan", startedAt: now, duration: 60)
        let profile = SpeakerProfile(
            displayName: "Avery",
            centroid: [0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertCall(call)
        try await store.upsertSpeakerProfile(profile)
        try await store.replaceCallSpeakers(
            callID: call.id,
            speakers: [CallSpeaker(callID: call.id, clusterKey: "far", profileID: profile.id, confidence: 0.9)]
        )

        let analytics = try await store.fetchDashboardAnalytics(asOf: now)

        #expect(analytics.calls[0].counterpartyName == "Morgan")
        #expect(analytics.contacts.map(\.name) == ["Morgan"])
    }

    @Test func groupLabelFollowsTheMostRecentCallWithoutRelabellingOlderCalls() async throws {
        let store = MemoryStore()
        let profile = SpeakerProfile(
            displayName: "Avery",
            centroid: [0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        let matched = fixtureCall(counterparty: nil, startedAt: now.addingTimeInterval(-3_600), duration: 60)
        let shouted = fixtureCall(counterparty: "AVERY", startedAt: now, duration: 60)
        try await store.upsertSpeakerProfile(profile)
        try await store.upsertCall(matched)
        try await store.upsertCall(shouted)
        try await store.replaceCallSpeakers(
            callID: matched.id,
            speakers: [CallSpeaker(callID: matched.id, clusterKey: "far", profileID: profile.id, confidence: 0.9)]
        )

        let analytics = try await store.fetchDashboardAnalytics(asOf: now)
        let resolved = try #require(analytics.calls.first { $0.id == matched.id })

        #expect(resolved.counterpartyName == "Avery")
        #expect(analytics.contacts.map(\.name) == ["AVERY"])
        #expect(analytics.contacts[0].callCount == 2)
    }

    @Test func editedCounterpartyNameWinsOverAStaleResolvedIdentity() {
        let call = fixtureCall(counterparty: "Priya", startedAt: now, duration: 60)

        let analytics = DashboardAnalytics.make(
            from: [call],
            counterpartyNames: [call.id: "Unknown"],
            now: now,
            calendar: calendar
        )

        #expect(analytics.calls[0].counterpartyName == "Priya")
        #expect(analytics.contacts.map(\.name) == ["Priya"])
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

    @Test func localFallbackWithMetaBillingIsMixedAndRetainsItsCost() {
        let call = fixtureCall(
            counterparty: "Avery",
            startedAt: now.addingTimeInterval(-60),
            duration: 60,
            engine: .appleSpeech,
            billedSeconds: 60
        )

        let analytics = DashboardAnalytics.make(from: [call], now: now, calendar: calendar)

        #expect(analytics.calls[0].engine == .mixed)
        #expect(analytics.totals.localCallCount == 0)
        #expect(analytics.totals.metaCallCount == 0)
        #expect(analytics.totals.mixedCallCount == 1)
        #expect(analytics.totals.metaBilledSeconds == 60)
        #expect(abs(analytics.totals.metaCostDollars - 0.003) < 0.000_000_1)
    }

    @Test func retranscriptionPersistsBothEnginesForMixedDashboardReporting() async throws {
        let store = MemoryStore()
        var call = fixtureCall(counterparty: "Avery", startedAt: now, duration: 60)
        try await store.upsertCall(call)

        call.sttProvider = .metaMuse
        call.metaBilledSec = 60
        try await store.upsertCall(call)

        let persisted = try #require(await store.fetchCall(id: call.id))
        let analytics = try await store.fetchDashboardAnalytics(asOf: now)

        #expect(persisted.transcriptionProviders == [.appleSpeech, .metaMuse])
        #expect(analytics.calls[0].engine == .mixed)
        #expect(analytics.totals.mixedCallCount == 1)
        #expect(abs(analytics.calls[0].costDollars - 0.003) < 0.000_000_1)
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
        try await store.migrate()
        try await sweepLeftoverPostgresFixtures(store)
        try await withIsolatedPostgresFixtures(store) { callIDs, profileIDs in
            let fixtureName = "\(Self.fixturePrefix)\(UUID().uuidString)"
            let calls = [
                fixtureCall(counterparty: fixtureName, startedAt: now.addingTimeInterval(-120), duration: 120),
                fixtureCall(
                    counterparty: fixtureName,
                    startedAt: now.addingTimeInterval(-60),
                    duration: 180,
                    engine: .metaMuse,
                    billedSeconds: 60
                ),
            ]
            for call in calls {
                try await store.upsertCall(call)
                callIDs.append(call.id)
            }

            let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
            let contact = try #require(snapshot.contacts.first { $0.name == fixtureName })
            let seededCalls = snapshot.calls.filter { Set(calls.map(\.id)).contains($0.id) }

            #expect(contact.callCount == 2)
            #expect(contact.totalDurationSec == 300)
            #expect(seededCalls.reduce(0) { $0 + $1.durationSec } == 300)
            #expect(abs(seededCalls.reduce(0) { $0 + $1.costDollars } - 0.003) < 0.000_000_1)

            var retranscribed = fixtureCall(
                counterparty: "\(fixtureName) reprocessed",
                startedAt: now,
                duration: 60
            )
            try await store.upsertCall(retranscribed)
            callIDs.append(retranscribed.id)
            retranscribed.sttProvider = .metaMuse
            retranscribed.metaBilledSec = 60
            try await store.upsertCall(retranscribed)

            let refreshed = try await store.fetchDashboardAnalytics(asOf: now)
            let mixed = try #require(refreshed.calls.first { $0.id == retranscribed.id })
            #expect(mixed.engine == .mixed)
            #expect(abs(mixed.costDollars - 0.003) < 0.000_000_1)

            let profile = SpeakerProfile(
                displayName: "\(fixtureName) profile",
                centroid: [0],
                embeddingModel: EmbeddingModel.weSpeakerV2
            )
            let profileCall = fixtureCall(counterparty: nil, startedAt: now, duration: 60)
            try await store.upsertSpeakerProfile(profile)
            profileIDs.append(profile.id)
            try await store.upsertCall(profileCall)
            callIDs.append(profileCall.id)
            try await store.replaceCallSpeakers(
                callID: profileCall.id,
                speakers: [CallSpeaker(callID: profileCall.id, clusterKey: "far", profileID: profile.id, confidence: 0.9)]
            )

            let shoutedName = profile.displayName.uppercased()
            let shoutedCall = fixtureCall(
                counterparty: shoutedName,
                startedAt: now.addingTimeInterval(60),
                duration: 30
            )
            try await store.upsertCall(shoutedCall)
            callIDs.append(shoutedCall.id)

            let profileSnapshot = try await store.fetchDashboardAnalytics(asOf: now)
            let resolved = try #require(profileSnapshot.calls.first { $0.id == profileCall.id })
            let group = try #require(profileSnapshot.contacts.first { $0.callIDs.contains(profileCall.id) })

            #expect(resolved.counterpartyName == profile.displayName)
            #expect(group.name == shoutedName)
            #expect(group.callCount == 2)
        }
    }

    private static let fixturePrefix = "Dashboard fixture "

    /// Removes every row a killed run can strand: a leaked non-owner profile also
    /// silently disables counterparty-name suggestion for real calls.
    private func sweepLeftoverPostgresFixtures(_ store: PostgresStore) async throws {
        let leftoverCalls = try await store.fetchCalls().filter { $0.audioPath == Self.fixtureAudioPath }
        let leftoverProfiles = try await store.fetchSpeakerProfiles().filter {
            !$0.isOwner && $0.displayName.hasPrefix(Self.fixturePrefix)
        }
        try await store.removeTestFixtures(
            callIDs: leftoverCalls.map(\.id),
            profileIDs: leftoverProfiles.map(\.id)
        )
    }

    private func withIsolatedPostgresFixtures(
        _ store: PostgresStore,
        _ work: (inout [UUID], inout [UUID]) async throws -> Void
    ) async throws {
        var callIDs: [UUID] = []
        var profileIDs: [UUID] = []
        do {
            try await work(&callIDs, &profileIDs)
        } catch {
            try? await store.removeTestFixtures(callIDs: callIDs, profileIDs: profileIDs)
            throw error
        }
        try await store.removeTestFixtures(callIDs: callIDs, profileIDs: profileIDs)
        for id in callIDs {
            #expect(try await store.fetchCall(id: id) == nil)
        }
        let remainingProfiles = try await store.fetchSpeakerProfiles()
        #expect(remainingProfiles.allSatisfy { !profileIDs.contains($0.id) })
    }

    private static let fixtureAudioPath = "/tmp/dashboard-fixture.caf"

    private func fixtureCall(
        counterparty: String?,
        number: String? = nil,
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
            counterpartyNumber: number,
            audioPath: Self.fixtureAudioPath,
            sttProvider: engine,
            status: .transcribed,
            metaBilledSec: billedSeconds
        )
    }
}
