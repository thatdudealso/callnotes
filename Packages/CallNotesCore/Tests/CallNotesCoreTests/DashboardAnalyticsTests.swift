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

    @Test func groupsRepeatCallersAndUnknownContactsWithTalkTime() throws {
        let calls = [
            fixtureCall(counterparty: "Avery", startedAt: now.addingTimeInterval(-86_400), duration: 120),
            fixtureCall(counterparty: " Avery\n", startedAt: now.addingTimeInterval(-3_600), duration: 180),
            fixtureCall(counterparty: nil, startedAt: now.addingTimeInterval(-1_800), duration: 90),
            fixtureCall(counterparty: "", startedAt: now.addingTimeInterval(-900), duration: 30),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let avery = try #require(analytics.contacts.first { $0.name == "Avery" })
        let unknown = try #require(analytics.contacts.first { $0.name == "Unknown" })

        #expect(avery.callCount == 2)
        #expect(avery.totalDurationSec == 300)
        #expect(avery.averageDurationSec == 150)
        #expect(avery.lastContactedAt == now.addingTimeInterval(-3_600))
        #expect(unknown.callCount == 2)
        #expect(unknown.totalDurationSec == 120)
        #expect(unknown.averageDurationSec == 60)
    }

    @Test func groupsCounterpartyNamesCaseInsensitivelyRegardlessOfNumber() throws {
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
        let alex = try #require(analytics.contacts.first { $0.name == "Alex" })

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

    @Test func manyCallsAggregateDayWeekAndMonthAndKeepDrillDownIDs() throws {
        let calls = [
            fixtureCall(counterparty: "Avery", startedAt: now.addingTimeInterval(-3_600), duration: 120, engine: .appleSpeech),
            fixtureCall(counterparty: "Mina", startedAt: now.addingTimeInterval(-86_400), duration: 180, engine: .metaMuse, billedSeconds: 60),
            fixtureCall(counterparty: "Jon", startedAt: now.addingTimeInterval(-9 * 86_400), duration: 240, engine: .metaMuse, billedSeconds: 120),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let today = try #require(analytics.periods.first { $0.range == .day && $0.callCount == 1 })
        let week = try #require(analytics.periods.first { $0.range == .week && $0.callCount == 2 })
        let month = try #require(analytics.periods.first { $0.range == .month && $0.callCount == 3 })

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
        let call = fixtureCall(counterparty: "Avery", startedAt: now, duration: 60)
        let published = Task {
            for await _ in changes { return true }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            published.cancel()
        }

        try await store.upsertCall(call)

        #expect(await published.value)
        deadline.cancel()
        let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
        #expect(snapshot.totals.callCount == 1)
        #expect(snapshot.calls.map(\.id) == [call.id])
    }

    @Test func openEndedTranscribingCallAddsNoTalkTimeAndIsMarkedIncomplete() throws {
        let calls = [
            processingCall(startedAt: now.addingTimeInterval(-7 * 86_400), status: .transcribing),
            fixtureCall(counterparty: "Avery", startedAt: now.addingTimeInterval(-60), duration: 120),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let stalled = try #require(analytics.calls.first { $0.id == calls[0].id })
        let avery = try #require(analytics.contacts.first { $0.name == "Avery" })

        #expect(stalled.isIncomplete)
        #expect(stalled.durationSec == 0)
        #expect(analytics.totals.callCount == 2)
        #expect(analytics.totals.totalDurationSec == 120)
        #expect(analytics.totals.incompleteCallCount == 1)
        #expect(avery.callCount == 2)
        #expect(avery.totalDurationSec == 120)
        #expect(avery.averageDurationSec == 120)
        #expect(analytics.periods.allSatisfy { $0.totalDurationSec <= 120 })
    }

    @Test func failedCallStampedAtGiveUpTimeAddsNoTalkTimeAndIsMarkedIncomplete() throws {
        let failed = failedImportCall(startedAt: now.addingTimeInterval(-600), gaveUpAt: now)
        let calls = [
            failed,
            fixtureCall(counterparty: "Avery", startedAt: now.addingTimeInterval(-60), duration: 120),
        ]

        let analytics = DashboardAnalytics.make(from: calls, now: now, calendar: calendar)
        let failedRow = try #require(analytics.calls.first { $0.id == failed.id })
        let avery = try #require(analytics.contacts.first { $0.name == "Avery" })

        #expect(failedRow.isIncomplete)
        #expect(failedRow.durationSec == 0)
        #expect(analytics.totals.totalDurationSec == 120)
        #expect(analytics.totals.incompleteCallCount == 1)
        #expect(avery.callCount == 2)
        #expect(avery.totalDurationSec == 120)
        #expect(avery.averageDurationSec == 120)
        #expect(analytics.periods.allSatisfy { $0.totalDurationSec <= 120 })
    }

    @Test func failedCallKeepsAMeasuredDurationAndItsBilledCost() throws {
        var failed = failedImportCall(startedAt: now.addingTimeInterval(-600), gaveUpAt: now)
        failed.durationSec = 300
        failed.metaBilledSec = 300

        let analytics = DashboardAnalytics.make(from: [failed], now: now, calendar: calendar)
        let row = try #require(analytics.calls.first { $0.id == failed.id })

        #expect(!row.isIncomplete)
        #expect(row.durationSec == 300)
        #expect(analytics.totals.totalDurationSec == 300)
        #expect(row.costDollars == MetaCostMeter.costDollars(billedSeconds: 300))
    }

    @Test func openEndedRecordingStillExtrapolatesWhileIncompleteProcessingDoesNot() throws {
        let live = processingCall(startedAt: now.addingTimeInterval(-120), status: .recording)
        let stalled = processingCall(startedAt: now.addingTimeInterval(-120), status: .uploaded)

        let analytics = DashboardAnalytics.make(from: [live, stalled], now: now, calendar: calendar)
        let liveRow = try #require(analytics.calls.first { $0.id == live.id })
        let stalledRow = try #require(analytics.calls.first { $0.id == stalled.id })

        #expect(liveRow.durationSec == 120)
        #expect(!liveRow.isIncomplete)
        #expect(stalledRow.durationSec == 0)
        #expect(stalledRow.isIncomplete)
        #expect(analytics.totals.totalDurationSec == 120)
    }

    @Test func strandedRecordingIsClosedAtItsLastSegmentInsteadOfExtrapolating() async throws {
        let store = MemoryStore()
        let stranded = recordingCall(startedAt: now.addingTimeInterval(-7 * 86_400))
        try await store.upsertCall(stranded)
        try await store.replaceSegments(
            callID: stranded.id,
            provider: .appleSpeech,
            [
                Segment(callID: stranded.id, seq: 0, startSec: 0, endSec: 90, channel: .near, text: "one", provider: .appleSpeech),
                Segment(callID: stranded.id, seq: 1, startSec: 90, endSec: 180.75, channel: .far, text: "two", provider: .appleSpeech),
            ]
        )

        let repaired = try #require(try await store.closeStrandedRecordings(excluding: nil).first)
        let analytics = try await store.fetchDashboardAnalytics(asOf: now)

        #expect(repaired.durationSec == 180)
        #expect(repaired.endedAt == stranded.startedAt.addingTimeInterval(180.75))
        #expect(repaired.status == .transcribed)
        #expect(analytics.totals.totalDurationSec == 180)
    }

    @Test func strandedRecordingWithoutSegmentsClosesAtZeroAndIsMarkedFailed() async throws {
        let store = MemoryStore()
        let stranded = recordingCall(startedAt: now.addingTimeInterval(-7 * 86_400))
        try await store.upsertCall(stranded)

        let repaired = try #require(try await store.closeStrandedRecordings(excluding: nil).first)
        let analytics = try await store.fetchDashboardAnalytics(asOf: now)

        #expect(repaired.durationSec == 0)
        #expect(repaired.endedAt == stranded.startedAt)
        #expect(repaired.status == .failed)
        #expect(analytics.totals.totalDurationSec == 0)
    }

    @Test func liveRecordingIsLeftAloneAndKeepsExtrapolatingToNow() async throws {
        let store = MemoryStore()
        let live = recordingCall(startedAt: now.addingTimeInterval(-120))
        try await store.upsertCall(live)

        let repaired = try await store.closeStrandedRecordings(excluding: live.id)
        let persisted = try #require(await store.fetchCall(id: live.id))
        let analytics = try await store.fetchDashboardAnalytics(asOf: now)

        #expect(repaired.isEmpty)
        #expect(persisted.status == .recording)
        #expect(persisted.endedAt == nil)
        #expect(analytics.totals.totalDurationSec == 120)
    }

    @Test func finishedLiveSessionReachesTheDashboardThroughTheStoreObserver() async throws {
        let store = MemoryStore()
        var call = recordingCall(startedAt: now.addingTimeInterval(-120))
        call.sttProvider = .metaMuse
        try await store.upsertCall(call)
        let published = try await observedChange(from: store) {
            call.metaBilledSec += 60
            call.endedAt = self.now
            call.durationSec = 120
            call.status = .transcribed
            call.sttProvider = .appleSpeech
            try await store.replaceSegments(
                callID: call.id,
                provider: .appleSpeech,
                [Segment(callID: call.id, seq: 0, startSec: 0, endSec: 120, channel: .near, text: "hi", provider: .appleSpeech)]
            )
            try await store.upsertCall(call)
        }

        let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
        let row = try #require(snapshot.calls.first { $0.id == call.id })

        #expect(published)
        #expect(row.durationSec == 120)
        #expect(row.engine == .mixed)
        #expect(abs(row.costDollars - 0.003) < 0.000_000_1)
        #expect(snapshot.totals.totalDurationSec == 120)
    }

    @Test func retranscriptionReachesTheDashboardThroughTheStoreObserver() async throws {
        let store = MemoryStore()
        var call = fixtureCall(counterparty: "Avery", startedAt: now, duration: 60)
        try await store.upsertCall(call)
        let published = try await observedChange(from: store) {
            try await store.replaceSegments(
                callID: call.id,
                provider: .metaMuse,
                [Segment(callID: call.id, seq: 0, startSec: 0, endSec: 60, channel: .near, text: "hi", provider: .metaMuse)]
            )
            call.sttProvider = .metaMuse
            call.status = .transcribed
            try await store.upsertCall(call)
            call.metaBilledSec += 60
            try await store.upsertCall(call)
        }

        let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
        let row = try #require(snapshot.calls.first { $0.id == call.id })

        #expect(published)
        #expect(row.engine == .mixed)
        #expect(abs(row.costDollars - 0.003) < 0.000_000_1)
        #expect(abs(snapshot.totals.metaCostDollars - 0.003) < 0.000_000_1)
    }

    @Test func fixtureSweepNeverSelectsACallOutsideTheTestNamespace() {
        let seeded = fixtureCall(counterparty: "Avery", startedAt: now, duration: 60)
        var imported = seeded
        imported.audioPath = "/tmp/dashboard-fixture.caf"

        #expect(Self.isStrandedFixture(seeded))
        #expect(!Self.isStrandedFixture(imported))
    }

    @Test func batchedPreferredNotesMatchThePerCallPreference() async throws {
        let store = MemoryStore()
        let deep = fixtureCall(counterparty: "Avery", startedAt: now, duration: 60)
        let instantOnly = fixtureCall(counterparty: "Mina", startedAt: now, duration: 60)
        try await store.upsertCall(deep)
        try await store.upsertCall(instantOnly)
        try await store.upsertNotes(fixtureNotes(callID: deep.id, provider: .glimmer, at: now))
        try await store.upsertNotes(
            fixtureNotes(callID: deep.id, provider: .appleFM, at: now.addingTimeInterval(60))
        )
        try await store.upsertNotes(fixtureNotes(callID: instantOnly.id, provider: .appleFM, at: now))

        let batched = try await store.fetchPreferredNotesByCall()
        let perCall = try await store.fetchPreferredNotes(callID: deep.id)

        #expect(batched[deep.id] == perCall)
        #expect(batched[deep.id]?.provider == .glimmer)
        #expect(batched[instantOnly.id]?.provider == .appleFM)
        #expect(batched.count == 2)
    }

    @Test func seededPostgresFixturePreservesContactAndCostTruth() async throws {
        guard let store = await PostgresStore.makeIfAvailable() else { return }
        try await store.migrate()
        try await sweepLeftoverPostgresFixtures(store)
        try await withIsolatedPostgresFixtures(store) { callIDs, profileIDs in
            let fixtureName = "\(Self.fixturePrefix)\(UUID().uuidString)"
            let calls = [
                fixtureCall(
                    counterparty: "\(fixtureName)\n",
                    startedAt: now.addingTimeInterval(-180),
                    duration: 60
                ),
                fixtureCall(counterparty: fixtureName, startedAt: now.addingTimeInterval(-120), duration: 120),
                fixtureCall(
                    counterparty: fixtureName,
                    startedAt: now.addingTimeInterval(-60),
                    duration: 180,
                    engine: .metaMuse,
                    billedSeconds: 60
                ),
            ]
            let changes = await store.dashboardChanges()
            let published = Task {
                for await _ in changes { return true }
                return false
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(5))
                published.cancel()
            }
            for call in calls {
                try await store.upsertCall(call)
                callIDs.append(call.id)
            }

            #expect(await published.value)
            deadline.cancel()

            let snapshot = try await store.fetchDashboardAnalytics(asOf: now)
            let contact = try #require(snapshot.contacts.first { $0.name == fixtureName })
            let seededCalls = snapshot.calls.filter { Set(calls.map(\.id)).contains($0.id) }

            #expect(contact.callCount == 3)
            #expect(contact.totalDurationSec == 360)
            #expect(seededCalls.allSatisfy { $0.counterpartyName == fixtureName })
            #expect(seededCalls.reduce(0) { $0 + $1.durationSec } == 360)
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

            try await store.upsertNotes(fixtureNotes(callID: profileCall.id, provider: .glimmer, at: now))
            try await store.upsertNotes(
                fixtureNotes(callID: profileCall.id, provider: .appleFM, at: now.addingTimeInterval(60))
            )
            let batchedNotes = try await store.fetchPreferredNotesByCall()
            let perCallNotes = try await store.fetchPreferredNotes(callID: profileCall.id)
            #expect(batchedNotes[profileCall.id] == perCallNotes)
            #expect(batchedNotes[profileCall.id]?.provider == .glimmer)

            let unrelated = Call(
                source: .fileImport,
                startedAt: now.addingTimeInterval(-30),
                endedAt: now,
                durationSec: 30,
                counterpartyName: "\(fixtureName) unrelated",
                audioPath: "/tmp/dashboard-fixture.caf",
                sttProvider: .appleSpeech,
                status: .transcribed
            )
            try await store.upsertCall(unrelated)
            callIDs.append(unrelated.id)

            let sweepTargets = try await store.fetchCalls().filter(Self.isStrandedFixture)

            #expect(!sweepTargets.contains { $0.id == unrelated.id })
            #expect(sweepTargets.contains { $0.id == profileCall.id })

            let stalledName = "\(fixtureName) stalled"
            let stalled = processingCall(
                counterparty: stalledName,
                startedAt: now.addingTimeInterval(-7 * 86_400),
                status: .transcribing
            )
            try await store.upsertCall(stalled)
            callIDs.append(stalled.id)
            let stalledSibling = fixtureCall(
                counterparty: stalledName,
                startedAt: now.addingTimeInterval(-60),
                duration: 120
            )
            try await store.upsertCall(stalledSibling)
            callIDs.append(stalledSibling.id)

            let stalledSnapshot = try await store.fetchDashboardAnalytics(asOf: now)
            let stalledRow = try #require(stalledSnapshot.calls.first { $0.id == stalled.id })
            let stalledContact = try #require(stalledSnapshot.contacts.first { $0.name == stalledName })
            let persistedStalled = try #require(await store.fetchCall(id: stalled.id))

            #expect(stalledRow.durationSec == 0)
            #expect(stalledRow.isIncomplete)
            #expect(persistedStalled.status == .transcribing)
            #expect(stalledContact.callCount == 2)
            #expect(stalledContact.totalDurationSec == 120)
            #expect(stalledContact.averageDurationSec == 120)

            let failedName = "\(fixtureName) failed"
            let failedImport = failedImportCall(
                counterparty: failedName,
                startedAt: now.addingTimeInterval(-600),
                gaveUpAt: now
            )
            try await store.upsertCall(failedImport)
            callIDs.append(failedImport.id)
            let failedSibling = fixtureCall(
                counterparty: failedName,
                startedAt: now.addingTimeInterval(-60),
                duration: 90
            )
            try await store.upsertCall(failedSibling)
            callIDs.append(failedSibling.id)

            let failedSnapshot = try await store.fetchDashboardAnalytics(asOf: now)
            let failedRow = try #require(failedSnapshot.calls.first { $0.id == failedImport.id })
            let failedContact = try #require(failedSnapshot.contacts.first { $0.name == failedName })

            #expect(failedRow.durationSec == 0)
            #expect(failedRow.isIncomplete)
            #expect(failedContact.callCount == 2)
            #expect(failedContact.totalDurationSec == 90)
            #expect(failedContact.averageDurationSec == 90)

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

    private static let fixturePrefix = "\(Self.fixtureNamespace) "

    /// Keyed on a namespace only this suite writes to, so the sweep can never reach
    /// a real call that merely shares a plausible audio path.
    /// Runs `writes` with a live `dashboardChanges()` subscription and reports whether
    /// the store published, so a path can be proven to reach the dashboard without any
    /// manual refresh. Bounded so a missing notification fails instead of hanging.
    private func observedChange(
        from store: some CallStore,
        _ writes: () async throws -> Void
    ) async throws -> Bool {
        let changes = await store.dashboardChanges()
        let published = Task {
            for await _ in changes { return true }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            published.cancel()
        }
        try await writes()
        let result = await published.value
        deadline.cancel()
        return result
    }

    private static func isStrandedFixture(_ call: Call) -> Bool {
        call.audioPath.hasPrefix(fixtureAudioRoot)
    }

    /// Removes every row a killed run can strand: a leaked non-owner profile also
    /// silently disables counterparty-name suggestion for real calls.
    private func sweepLeftoverPostgresFixtures(_ store: PostgresStore) async throws {
        let leftoverCalls = try await store.fetchCalls().filter(Self.isStrandedFixture)
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

    private static let fixtureNamespace = "callnotes-dashboard-test-fixture"
    private static let fixtureAudioRoot = "/tmp/\(Self.fixtureNamespace)/"
    private static let fixtureAudioPath = "\(Self.fixtureAudioRoot)\(UUID().uuidString).caf"

    private func recordingCall(startedAt: Date) -> Call {
        processingCall(startedAt: startedAt, status: .recording)
    }

    /// Mirrors what an import that dies before its audio is measured leaves behind:
    /// `endedAt` stamped when processing gave up and no `durationSec` at all.
    private func failedImportCall(
        counterparty: String = "Avery",
        startedAt: Date,
        gaveUpAt: Date
    ) -> Call {
        Call(
            source: .fileImport,
            startedAt: startedAt,
            endedAt: gaveUpAt,
            counterpartyName: counterparty,
            audioPath: Self.fixtureAudioPath,
            sttProvider: .metaMuse,
            status: .failed,
            error: "Transcript was empty.",
            errorStage: "transcription"
        )
    }

    private func processingCall(
        counterparty: String = "Avery",
        startedAt: Date,
        status: CallStatus
    ) -> Call {
        Call(
            source: .macManual,
            startedAt: startedAt,
            counterpartyName: counterparty,
            audioPath: Self.fixtureAudioPath,
            sttProvider: .appleSpeech,
            status: status
        )
    }

    private func fixtureNotes(callID: UUID, provider: NotesProviderID, at createdAt: Date) -> NotesRecord {
        NotesRecord(
            callID: callID,
            provider: provider,
            body: CallNotes(title: "\(provider.rawValue) title", summary: "\(provider.rawValue) summary"),
            createdAt: createdAt
        )
    }

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
