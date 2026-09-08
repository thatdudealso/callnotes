import Foundation
import Testing

@testable import CallNotesCore

@Suite struct MetaTranscriptionTests {
    @Test func PCM24KHzPacingNeverAllowsMoreThanFiveSecondsAhead() {
        let byteRate = MetaAudioFormat.pcm24KHz.byteRate

        #expect(MetaRealtimePacing.requiredSleepNanoseconds(
            sentAudioBytes: byteRate * 6,
            elapsedNanoseconds: 0
        ) == 6_000_000_000)
        #expect(MetaRealtimePacing.isWithinBacklogLimit(
            sentAudioBytes: byteRate * 5,
            elapsedNanoseconds: 0
        ))
        #expect(!MetaRealtimePacing.isWithinBacklogLimit(
            sentAudioBytes: byteRate * 5 + 1,
            elapsedNanoseconds: 0
        ))
    }

    @Test func realtimeResamplingConvertsOnlyTheMetaIngressFormat() throws {
        var resampler = try MetaPCMResampler(inputSampleRate: 16_000)
        let input = Data.int16LittleEndian([0, Int16.max, 0, Int16.min])

        let output = resampler.convert(input)

        #expect(output.count == 12)
        #expect(MetaPCMResampler.samples(from: output).count == 6)
    }

    @Test func costIsRoundedDownToWholeSeconds() {
        #expect(MetaCostMeter.billedSeconds(audioProcessedMilliseconds: 1_999) == 1)
        #expect(MetaCostMeter.billedSeconds(audioProcessedMilliseconds: 2_000) == 2)
        #expect(MetaCostMeter.costDollars(billedSeconds: 3_600) == 0.18)
    }

    @Test func chunkPlanUsesNineAndAHalfMinuteChunksWithFiveSecondOverlap() {
        let plan = MetaFileChunker.plan(
            totalFrames: 24_000 * 601,
            sampleRate: 24_000
        )

        #expect(plan.count == 2)
        #expect(plan[0].startFrame == 0)
        #expect(plan[0].frameCount == 24_000 * 570)
        #expect(plan[1].startFrame == 24_000 * 565)
    }

    @Test func deduperRemovesTheRepeatedOverlapTurnButKeepsNewSpeech() {
        let previous = [
            RawSegment(start: 560, end: 564, text: "Let us review the proposal.", speakerTag: "A"),
            RawSegment(start: 565, end: 569, text: "I agree with that plan.", speakerTag: "B"),
        ]
        let incoming = [
            RawSegment(start: 0, end: 4, text: "I agree with that plan.", speakerTag: "B"),
            RawSegment(start: 5, end: 9, text: "I will send the contract today.", speakerTag: "A"),
        ]

        let merged = MetaTranscriptOverlapDeduper.merge(
            previous: previous,
            incoming: incoming,
            incomingOffset: 565
        )

        #expect(merged.map(\.text) == [
            "Let us review the proposal.",
            "I agree with that plan.",
            "I will send the contract today.",
        ])
    }

    @Test func speakerStitcherUsesLocalEmbeddingsInsteadOfSessionScopedLabels() {
        let alex = SpeakerProfile(
            displayName: "Alex",
            centroid: [1, 0, 0],
            embeddingModel: "test"
        )
        let priya = SpeakerProfile(
            displayName: "Priya",
            centroid: [0, 1, 0],
            embeddingModel: "test"
        )

        let stitcher = MetaSpeakerSessionStitcher(profiles: [alex, priya])
        let labels = stitcher.stitch([
            MetaSpeakerEmbedding(sessionID: "first", label: "A", embedding: [0.99, 0.01, 0]),
            MetaSpeakerEmbedding(sessionID: "reconnected", label: "B", embedding: [0.98, 0.02, 0]),
        ])

        #expect(labels["first:A"] == alex.id)
        #expect(labels["reconnected:B"] == alex.id)
    }

    @Test func metaSelectionRequiresOneTimeCloudDisclosure() {
        let gate = MetaPrivacyGate()

        #expect(gate.requiresDisclosure(for: .metaMuse, hasAcknowledged: false))
        #expect(!gate.requiresDisclosure(for: .appleSpeech, hasAcknowledged: false))
        #expect(!gate.requiresDisclosure(for: .metaMuse, hasAcknowledged: true))
    }

    @Test func realtimeReducerUsesCumulativePartialsAndKeysOverlappingTurnsByTurnID() throws {
        var reducer = MetaRealtimeEventReducer(timelineOffset: 600)
        #expect(try reducer.consume(json: #"{"type":"speechStart","turnId":1,"audioProcessedMs":1000}"#) == nil)
        #expect(try reducer.consume(json: #"{"type":"speaker","label":"A","audioProcessedMs":1200}"#) == nil)
        let partialResult = try reducer.consume(json: #"{"type":"transcript","transcript":"hello there","final":false,"audioProcessedMs":1400}"#)
        let partial = try #require(partialResult)
        #expect(partial.text == "hello there")
        #expect(partial.isVolatile)
        #expect(partial.speakerTag == "A")
        #expect(partial.start == 601)

        // Turn 2 begins before turn 1 completes, as the API permits.
        #expect(try reducer.consume(json: #"{"type":"speechStart","turnId":2,"audioProcessedMs":1500}"#) == nil)
        #expect(try reducer.consume(json: #"{"type":"speaker","turnId":1,"label":"A","audioProcessedMs":1550}"#) == nil)
        let attributedPartialResult = try reducer.consume(json: #"{"type":"transcript","turnId":1,"transcript":"hello there","final":false,"audioProcessedMs":1560}"#)
        let attributedPartial = try #require(attributedPartialResult)
        #expect(attributedPartial.start == 601)
        #expect(attributedPartial.speakerTag == "A")
        let firstFinalResult = try reducer.consume(json: #"{"type":"speechComplete","turnId":1,"transcript":"Hello there.","audioProcessedMs":1600}"#)
        let firstFinal = try #require(firstFinalResult)
        #expect(firstFinal.start == 601)
        #expect(firstFinal.end == 601.6)
        #expect(firstFinal.speakerTag == "A")
        let secondFinalResult = try reducer.consume(json: #"{"type":"speechComplete","turnId":2,"transcript":"A second turn.","audioProcessedMs":2200}"#)
        let secondFinal = try #require(secondFinalResult)
        #expect(secondFinal.start == 601.5)
        #expect(reducer.maximumAudioProcessedMilliseconds == 2200)
    }

    @Test func realtimeReducerDropsDuplicateFinalFromReconnectOverlap() throws {
        var reducer = MetaRealtimeEventReducer(timelineOffset: 565)
        _ = try reducer.consume(json: #"{"type":"speechStart","turnId":1,"audioProcessedMs":0}"#)
        let first = try reducer.consume(json: #"{"type":"speechComplete","turnId":1,"transcript":"I agree with that plan.","audioProcessedMs":4000}"#)
        _ = try reducer.consume(json: #"{"type":"speechStart","turnId":2,"audioProcessedMs":0}"#)
        let duplicate = try reducer.consume(json: #"{"type":"speechComplete","turnId":2,"transcript":"I agree with that plan.","audioProcessedMs":4000}"#)
        #expect(first != nil)
        #expect(duplicate == nil)
    }

    @Test func primaryRealtimeFailureFlushesBufferedLocalFallback() async throws {
        let primary = ProbeSession()
        let fallback = ProbeSession()
        let session = MetaFallbackSession(primary: primary, fallback: fallback)
        await session.start()
        let collector = Task<[RawSegment], Error> {
            var result: [RawSegment] = []
            for try await segment in session.results { result.append(segment) }
            return result
        }
        await fallback.emit(RawSegment(start: 0, end: 1, text: "Local transcript", channel: .mixed))
        await primary.fail()
        await Task.yield()
        await fallback.emit(RawSegment(start: 1, end: 2, text: "Continues locally", channel: .mixed))
        try await session.finish()
        let results = try await collector.value

        let isUsingFallback = await session.isUsingFallback()
        #expect(isUsingFallback)
        #expect(results.map(\.text) == ["Local transcript", "Continues locally"])
    }

    @Test func primaryFailureDoesNotRepeatAlreadyEmittedTranscript() async throws {
        let primary = ProbeSession()
        let fallback = ProbeSession()
        let session = MetaFallbackSession(primary: primary, fallback: fallback)
        await session.start()
        let collector = Task<[RawSegment], Error> {
            var result: [RawSegment] = []
            for try await segment in session.results { result.append(segment) }
            return result
        }
        await primary.emit(RawSegment(start: 0, end: 1, text: "Already delivered", channel: .mixed))
        await fallback.emit(RawSegment(start: 0, end: 1, text: "Already delivered", channel: .mixed))
        await primary.fail()
        await Task.yield()
        await fallback.emit(RawSegment(start: 1, end: 2, text: "New local speech", channel: .mixed))
        try await session.finish()

        let results = try await collector.value
        #expect(results.map(\.text) == ["Already delivered", "New local speech"])
    }
}

private enum ProbeError: Error { case induced }

private actor ProbeSession: STTSession {
    nonisolated let results: AsyncThrowingStream<RawSegment, Error>
    private let continuation: AsyncThrowingStream<RawSegment, Error>.Continuation

    init() {
        let stream = AsyncThrowingStream<RawSegment, Error>.makeStream()
        results = stream.stream
        continuation = stream.continuation
    }

    func append(pcm: Data) async throws {}
    func finish() async throws { continuation.finish() }
    func emit(_ segment: RawSegment) { continuation.yield(segment) }
    func fail() { continuation.finish(throwing: ProbeError.induced) }
}
