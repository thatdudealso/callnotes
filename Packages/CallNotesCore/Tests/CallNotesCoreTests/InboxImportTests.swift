@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import CallNotesCore

@Suite struct InboxImportTests {
    @Test func hiddenICloudAndNonAudioFilesAreRejected() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-inbox-filter-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let audio = temp.appendingPathComponent("call.m4a")
        let hidden = temp.appendingPathComponent(".DS_Store")
        let placeholder = temp.appendingPathComponent("call.m4a.icloud")
        let text = temp.appendingPathComponent("notes.txt")
        try! Data([1, 2, 3]).write(to: audio)
        try! Data([1]).write(to: hidden)
        try! Data([1]).write(to: placeholder)
        try! Data([1]).write(to: text)

        #expect(InboxCandidate.isImportable(audio))
        #expect(!InboxCandidate.isImportable(hidden))
        #expect(!InboxCandidate.isImportable(placeholder))
        #expect(!InboxCandidate.isImportable(text))
        #expect(
            InboxDirectoryScanner().candidates(in: temp).map(\.lastPathComponent) == ["call.m4a"]
        )
    }

    @Test func settlerIgnoresGrowingFilesThenAcceptsAStableSize() async {
        let settler = InboxFileSettler(settleDuration: 0.05, pollInterval: 0.01)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-settle-\(UUID().uuidString).m4a")
        try! Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let t0 = Date()
        #expect(await settler.observe(url, now: t0) == false)
        try! Data([0, 1, 2, 3]).write(to: url)
        #expect(await settler.observe(url, now: t0.addingTimeInterval(0.2)) == false)
        #expect(await settler.observe(url, now: t0.addingTimeInterval(0.21)) == false)
        #expect(await settler.observe(url, now: t0.addingTimeInterval(0.27)))
    }

    @Test func duplicateIndexRejectsTheSameContent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-dup-\(UUID().uuidString).wav")
        try Data("same-bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = InboxDuplicateIndex()

        #expect(try await index.remember(url))
        #expect(try await index.remember(url) == false)
    }

    @Test func watcherScanEmitsASettledFileOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drop.m4a")
        try Data([1, 2, 3, 4]).write(to: file)

        let watcher = InboxWatcher(
            directory: directory,
            settler: InboxFileSettler(settleDuration: 0, pollInterval: 0.01),
            pollInterval: 60
        )
        #expect(await watcher.scanNow().isEmpty)
        let ready = await watcher.scanNow()
        #expect(ready.map(\.lastPathComponent) == ["drop.m4a"])
        #expect(await watcher.scanNow().isEmpty)

        try Data([5, 6, 7, 8, 9]).write(to: file)
        #expect(await watcher.scanNow().isEmpty)
        let replacement = await watcher.scanNow()
        #expect(replacement.map(\.lastPathComponent) == ["drop.m4a"])
    }
}

@Suite struct ImportChunkStitchTests {
    @Test func longImportPlanUsesNineAndAHalfMinuteChunksWithFiveSecondOverlap() {
        let plan = ImportFileChunker.plan(totalFrames: 16_000 * 601, sampleRate: 16_000)
        #expect(plan.count == 2)
        #expect(plan[0].startFrame == 0)
        #expect(plan[0].frameCount == 16_000 * 570)
        #expect(plan[1].startFrame == 16_000 * 565)
    }

    @Test func overlapDeduperDropsTheSeamRepeatAndKeepsNewSpeech() {
        let previous = [
            RawSegment(start: 560, end: 564, text: "Let us review the proposal.", speakerTag: "A"),
            RawSegment(start: 565, end: 569, text: "I agree with that plan.", speakerTag: "B"),
        ]
        let incoming = [
            RawSegment(start: 0, end: 4, text: "I agree with that plan.", speakerTag: "B"),
            RawSegment(start: 5, end: 9, text: "I will send the contract today.", speakerTag: "A"),
        ]
        let merged = ImportTranscriptOverlapDeduper.merge(
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

    @Test func overlapDeduperTrimsResegmentedSeamWords() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(start: 564, end: 570, text: "I agree with", channel: .mixed),
            ],
            incoming: [
                RawSegment(start: 0, end: 2, text: "with that plan", channel: .mixed),
            ],
            incomingOffset: 565
        )

        #expect(merged.map(\.text).joined(separator: " ") == "I agree with that plan")
    }

    @Test func overlapDeduperTrimsAcrossResegmentedPriorTail() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(start: 564, end: 567, text: "I agree", channel: .mixed),
                RawSegment(start: 567, end: 570, text: "with", channel: .mixed),
            ],
            incoming: [
                RawSegment(start: 0, end: 3, text: "I agree with that plan", channel: .mixed),
            ],
            incomingOffset: 565
        )

        #expect(merged.map(\.text).joined(separator: " ") == "I agree with that plan")
    }

    @Test func overlapDeduperPreservesCrosstalkOutsideTheMatchingTail() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(start: 564, end: 570, text: "I agree with", channel: .mixed),
                RawSegment(start: 565, end: 570, text: "yes", channel: .mixed),
            ],
            incoming: [
                RawSegment(start: 0, end: 3, text: "with that plan", channel: .mixed),
            ],
            incomingOffset: 565
        )

        #expect(merged.filter { $0.text != "yes" }.map(\.text).joined(separator: " ") == "I agree with that plan")
        #expect(merged.filter { $0.text == "yes" }.count == 1)
    }

    @Test func overlapDeduperTrimsResegmentedMetaSeamWordsAcrossTags() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(
                    start: 564,
                    end: 570,
                    text: "I agree with",
                    speakerTag: "speaker_0",
                    channel: .mixed
                ),
            ],
            incoming: [
                RawSegment(
                    start: 0,
                    end: 2,
                    text: "with that plan",
                    speakerTag: "speaker_1",
                    channel: .mixed
                ),
            ],
            incomingOffset: 565
        )

        #expect(merged.map(\.text).joined(separator: " ") == "I agree with that plan")
    }

    @Test func overlapDeduperKeepsBothSpeakersAcrossASimultaneousRetaggedSeam() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(start: 564, end: 570, text: "yes", speakerTag: "speaker_0", channel: .mixed),
                RawSegment(start: 565, end: 570, text: "yes", speakerTag: "speaker_1", channel: .mixed),
            ],
            incoming: [
                RawSegment(start: 0, end: 2, text: "yes next", speakerTag: "speaker_2", channel: .mixed),
            ],
            incomingOffset: 565
        )

        #expect(merged.map(\.text).joined(separator: " ") == "yes yes next")
        #expect(merged.map(\.speakerTag) == ["speaker_0", "speaker_1", "speaker_2"])
    }

    @Test func fileSpineChunksATenMinuteImportAndStitchesWithoutDupOrDrop() async throws {
        let store = MemoryStore()
        let pcm = Data(count: 16_000 * 601 * 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-long-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: pcm, sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let speech = SeamAwareTranscriber()
        let diarizer = ScriptedDiarizer(clusters: [
            DiarizedCluster(key: "A", ranges: [0...10], embedding: [0, 1, 0], embeddingModel: EmbeddingModel.weSpeakerV2)
        ])
        let spine = FileTranscriptionSpine(speech: speech, diarizer: diarizer, store: store)
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech,
            status: .uploaded
        )
        let progressTicks = LockBox<[ImportJob]>([])
        var reporting = spine
        reporting.onProgress = { job in progressTicks.value.append(job) }
        let processed = try await reporting.process(fileURL: url, call: call, profiles: [])

        #expect(processed.turns.map(\.text) == [
            "Opening the agenda.",
            "I agree with that plan.",
            "I will send the contract today.",
        ])
        #expect(progressTicks.value.contains { $0.chunkCount == 2 && $0.stage == .transcribing })
        let stored = try await store.fetchSegments(callID: call.id, provider: .appleSpeech)
        #expect(stored.map(\.text) == processed.turns.map(\.text))
    }
}

@Suite struct ImportPipelineTests {
    @Test func droppingM4AProducesTranscriptAndNotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let m4a = root.appendingPathComponent("inbox-drop.m4a")
        try ImportFixtureWriter.writeM4A(to: m4a, seconds: 0.4)

        let store = MemoryStore()
        let speech = ScriptedPCMTranscriber(
            near: [RawSegment(start: 0, end: 1, text: "We will ship the pilot next week.", channel: .mixed)],
            far: []
        )
        let diarizer = ScriptedDiarizer(clusters: [
            DiarizedCluster(key: "A", ranges: [0...1], embedding: [0, 1, 0], embeddingModel: EmbeddingModel.weSpeakerV2)
        ])
        let notesBody = CallNotes(title: "Pilot ship", summary: "Ship the pilot next week.")
        let notes = NotesGenerationSpine(
            instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
            deep: ScriptedNotesProvider(id: .glimmer, outputs: [.success(notesBody)]),
            fallback: ScriptedNotesProvider(id: .fallbackInstruct, outputs: [.success(notesBody)]),
            store: store
        )
        let jobs = LockBox<[ImportJob]>([])
        let pipeline = ImportPipeline(
            store: store,
            spine: FileTranscriptionSpine(speech: speech, diarizer: diarizer, store: store),
            notes: notes,
            duplicates: InboxDuplicateIndex(),
            audioRoot: root.appendingPathComponent("audio", isDirectory: true),
            onProgress: { job in jobs.value.append(job) }
        )

        let processed = try await pipeline.`import`(m4a, engine: .appleSpeech, counterpartyName: "Priya")

        #expect(processed.call.status == .notesReady)
        #expect(processed.call.source == .fileImport)
        #expect(processed.turns.contains { $0.text.contains("pilot") })
        #expect(try await store.fetchPreferredNotes(callID: processed.call.id)?.body.title == "Pilot ship")
        #expect(jobs.value.contains { $0.stage == .transcribing })
        #expect(jobs.value.contains { $0.stage == .notes })
        #expect(jobs.value.last?.stage == .completed)
    }

    @Test func secondDropOfTheSameBytesIsADuplicate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-dup-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("once.wav")
        try ImportFixtureWriter.writeWAV(to: file, seconds: 0.3)

        let store = MemoryStore()
        let pipeline = ImportPipeline(
            store: store,
            spine: FileTranscriptionSpine(
                speech: ScriptedPCMTranscriber(
                    near: [RawSegment(start: 0, end: 0.2, text: "Hello.", channel: .mixed)],
                    far: []
                ),
                diarizer: ScriptedDiarizer(clusters: []),
                store: store
            ),
            duplicates: InboxDuplicateIndex(),
            audioRoot: root.appendingPathComponent("audio", isDirectory: true)
        )
        _ = try await pipeline.`import`(file, engine: .appleSpeech)
        await #expect(throws: FileImportError.duplicate) {
            try await pipeline.`import`(file, engine: .appleSpeech)
        }
    }

    @Test func replacementDuringCopyRegistersTheCopiedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-copy-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("replace.wav")
        try ImportFixtureWriter.writeWAV(to: file, seconds: 0.3)

        let store = MemoryStore()
        let duplicates = InboxDuplicateIndex()
        let pipeline = ImportPipeline(
            store: store,
            spine: FileTranscriptionSpine(
                speech: ScriptedPCMTranscriber(
                    near: [RawSegment(start: 0, end: 0.2, text: "Hello.", channel: .mixed)],
                    far: []
                ),
                diarizer: ScriptedDiarizer(clusters: []),
                store: store
            ),
            duplicates: duplicates,
            audioRoot: root.appendingPathComponent("audio", isDirectory: true),
            onProgress: { job in
                guard job.stage == .copying else { return }
                try? ImportFixtureWriter.writeWAV(to: file, seconds: 0.4)
            }
        )

        _ = try await pipeline.`import`(file, engine: .appleSpeech)
        await #expect(throws: FileImportError.duplicate) {
            try await pipeline.`import`(file, engine: .appleSpeech)
        }
        #expect(try await store.fetchCalls().count == 1)
    }

    @Test func simulatedMetaImportPathStoresSegmentsWithoutANetworkCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-meta-sim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meta.wav")
        try ImportFixtureWriter.writeWAV(to: file, seconds: 0.4)
        let requested = LockBox<[URL]>([])
        let store = MemoryStore()
        let owner = SpeakerProfile(
            displayName: "Me",
            isOwner: true,
            centroid: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertSpeakerProfile(owner)
        let meta = SimulatedMetaFileProvider(
            segments: [
                RawSegment(start: 0, end: 1, text: "Cloud transcript of the import.", speakerTag: "speaker_0", channel: .mixed)
            ],
            billedSeconds: 1,
            onTranscribe: { url in requested.value.append(url) }
        )
        let pipeline = ImportPipeline(
            store: store,
            spine: FileTranscriptionSpine(
                speech: ScriptedPCMTranscriber(near: [], far: []),
                diarizer: ScriptedDiarizer(clusters: [
                    DiarizedCluster(
                        key: "A",
                        ranges: [0...1],
                        embedding: [1, 0, 0],
                        embeddingModel: EmbeddingModel.weSpeakerV2
                    )
                ]),
                store: store,
                meta: meta
            ),
            duplicates: InboxDuplicateIndex(),
            audioRoot: root.appendingPathComponent("audio", isDirectory: true)
        )

        let processed = try await pipeline.`import`(file, engine: .metaMuse)
        #expect(processed.call.sttProvider == .metaMuse)
        #expect(processed.call.metaBilledSec == 1)
        #expect(processed.turns.map(\.text) == ["Cloud transcript of the import."])
        #expect(processed.turns.map(\.speakerID) == [owner.id])
        #expect(processed.turns.map(\.clusterKey) == [TurnAttributor.ownerClusterKey])
        let storedSegments = try await store.fetchSegments(callID: processed.call.id, provider: .metaMuse)
        let storedSpeakers = try await store.fetchCallSpeakers(callID: processed.call.id)
        let reloaded = TurnAttributor.fromStored(
            segments: storedSegments,
            speakers: storedSpeakers,
            profiles: [owner]
        )
        #expect(reloaded.map(\.speakerID) == [owner.id])
        #expect(!requested.value.isEmpty)
    }

    @Test func failedMetaImportPersistsAccruedBilling() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-meta-failure-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 3_200), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .metaMuse,
            status: .uploaded
        )
        let spine = FileTranscriptionSpine(
            speech: ScriptedPCMTranscriber(near: [], far: []),
            diarizer: ScriptedDiarizer(clusters: []),
            store: store,
            meta: SimulatedMetaFileProvider(
                segments: [],
                error: MetaFileTranscriptionFailure(
                    billedSeconds: 570,
                    underlying: MetaTranscriptionError.backend("later chunk failed")
                )
            )
        )

        await #expect(throws: MetaFileTranscriptionFailure.self) {
            try await spine.process(fileURL: url, call: call, profiles: [])
        }
        let persisted = try await store.fetchCall(id: call.id)
        #expect(persisted?.status == .failed)
        #expect(persisted?.metaBilledSec == 570)
    }

    @Test func emptyMetaTranscriptPersistsAccruedBilling() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-meta-empty-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 3_200), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .metaMuse,
            status: .uploaded
        )
        let spine = FileTranscriptionSpine(
            speech: ScriptedPCMTranscriber(near: [], far: []),
            diarizer: ScriptedDiarizer(clusters: []),
            store: store,
            meta: SimulatedMetaFileProvider(segments: [], billedSeconds: 570)
        )

        await #expect(throws: FileImportError.emptyTranscript) {
            try await spine.process(fileURL: url, call: call, profiles: [])
        }
        let persisted = try await store.fetchCall(id: call.id)
        #expect(persisted?.status == .failed)
        #expect(persisted?.metaBilledSec == 570)
    }

    @Test func parakeetBatchModeIsWiredThroughTheSameSpine() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-parakeet-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 3200), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let speech = ScriptedPCMTranscriber(
            near: [RawSegment(start: 0, end: 0.1, text: "Parakeet import path.", channel: .mixed)],
            far: [],
            id: .fluidParakeet
        )
        let processed = try await FileTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        ).process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .fluidParakeet),
            profiles: []
        )
        #expect(processed.call.sttProvider == .fluidParakeet)
        #expect(processed.turns.map(\.text) == ["Parakeet import path."])
    }
}

@Suite struct AppleFileTranscriptionTests {
    @Test func non16KHzFileIsNormalizedBeforeAppleTranscription() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-apple-file-\(UUID().uuidString).wav")
        try ImportFixtureWriter.writeWAV(to: url, seconds: 1, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }

        let segments = try await AppleSpeechProvider().transcribeFile(
            fileURL: url,
            config: STTSessionConfig(sampleRate: 16_000)
        ) { pcm16, channel, config in
            [
                RawSegment(
                    start: 0,
                    end: Double(pcm16.count / 2) / Double(config.sampleRate),
                    text: "Normalized transcript.",
                    channel: channel
                )
            ]
        }

        #expect(segments.map(\.text) == ["Normalized transcript."])
        #expect(segments.map(\.end) == [1])
    }
}

@Suite struct FileAudioLoaderFormatTests {
    @Test func int32AndInt24SourcesDecodeToNonSilentPCM() throws {
        for (fileExtension, bitDepth) in [("wav", 32), ("aiff", 24)] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("callnotes-pcm\(bitDepth)-\(UUID().uuidString).\(fileExtension)")
            try ImportFixtureWriter.writeLinearPCMFile(to: url, seconds: 0.5, bitDepth: bitDepth, isFloat: false)
            defer { try? FileManager.default.removeItem(at: url) }

            let storedFormat = try AVAudioFile(forReading: url).fileFormat
            let stored = storedFormat.streamDescription.pointee
            #expect(stored.mBitsPerChannel == UInt32(bitDepth))
            #expect(stored.mFormatFlags & kAudioFormatFlagIsFloat == 0)

            let loaded = try FileAudioLoader.load(url)
            #expect(loaded.sampleRate == 16_000)
            #expect(loaded.near.count / 2 == 8_000)
            #expect(peakAmplitude(of: loaded.near) > 8_000)
        }
    }

    @Test func float64SourceDecodesToNonSilentPCM() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-pcm64-\(UUID().uuidString).wav")
        try ImportFixtureWriter.writeFloat64WAV(to: url, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        let storedFormat = try AVAudioFile(forReading: url).fileFormat
        let stored = storedFormat.streamDescription.pointee
        #expect(stored.mBitsPerChannel == 64)
        #expect(stored.mFormatFlags & kAudioFormatFlagIsFloat != 0)

        let loaded = try FileAudioLoader.load(url)
        #expect(loaded.sampleRate == 16_000)
        #expect(loaded.near.count / 2 == 8_000)
        #expect(peakAmplitude(of: loaded.near) > 8_000)
    }

    @Test func undecodableFileFailsInsteadOfImportingSilence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-not-audio-\(UUID().uuidString).wav")
        try Data("not an audio file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: FileImportError.self) {
            try FileAudioLoader.load(url)
        }
    }

    private func peakAmplitude(of pcm16: Data) -> Int {
        pcm16.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
        }
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private struct SeamAwareTranscriber: PCMTranscriber {
    let id: STTProviderID = .appleSpeech
    let dualInstanceMode: DualInstanceMode = .nearLiveFarBatch

    func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment] {
        let duration = Double(pcm16.count / 2) / Double(config.sampleRate)
        if duration > 100 {
            return [
                RawSegment(start: 0, end: 2, text: "Opening the agenda.", channel: channel),
                RawSegment(start: 565, end: 569, text: "I agree with that plan.", channel: channel),
            ]
        }
        return [
            RawSegment(start: 0, end: 4, text: "I agree with that plan.", channel: channel),
            RawSegment(start: 5, end: 9, text: "I will send the contract today.", channel: channel),
        ]
    }
}

enum ImportFixtureWriter {
    static func writeWAV(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        var samples = [Int16](repeating: 0, count: frames)
        for index in 0..<frames {
            let value = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
            samples[index] = Int16((value * 0.2) * Double(Int16.max))
        }
        let pcm = samples.withUnsafeBytes { Data($0) }
        var wav = Data("RIFF".utf8)
        wav.append(contentsOf: UInt32(36 + pcm.count).littleEndianBytes)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        wav.append(contentsOf: UInt32(16).littleEndianBytes)
        wav.append(contentsOf: UInt16(1).littleEndianBytes)
        wav.append(contentsOf: UInt16(1).littleEndianBytes)
        wav.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        wav.append(contentsOf: UInt32(sampleRate * 2).littleEndianBytes)
        wav.append(contentsOf: UInt16(2).littleEndianBytes)
        wav.append(contentsOf: UInt16(16).littleEndianBytes)
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: UInt32(pcm.count).littleEndianBytes)
        wav.append(pcm)
        try wav.write(to: url)
    }

    static func writeLinearPCMFile(
        to url: URL,
        seconds: Double,
        sampleRate: Int = 16_000,
        bitDepth: Int,
        isFloat: Bool
    ) throws {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ),
            let channel = buffer.floatChannelData
        else {
            throw FileImportError.invalidAudio("Could not build a linear PCM fixture buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            channel[0][index] = Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 0.5)
        }
        try file.write(from: buffer)
    }

    static func writeFloat64WAV(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        var pcm = Data()
        for index in 0..<frames {
            var sample = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 0.5
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        wav.append(contentsOf: UInt32(36 + pcm.count).littleEndianBytes)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        wav.append(contentsOf: UInt32(16).littleEndianBytes)
        wav.append(contentsOf: UInt16(3).littleEndianBytes)
        wav.append(contentsOf: UInt16(1).littleEndianBytes)
        wav.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        wav.append(contentsOf: UInt32(sampleRate * 8).littleEndianBytes)
        wav.append(contentsOf: UInt16(8).littleEndianBytes)
        wav.append(contentsOf: UInt16(64).littleEndianBytes)
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: UInt32(pcm.count).littleEndianBytes)
        wav.append(pcm)
        try wav.write(to: url)
    }

    static func writeM4A(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws {
        let wav = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-src.wav")
        try writeWAV(to: wav, seconds: seconds, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: wav) }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if let encoded = try? encodeM4A(fromWAV: wav, to: url, sampleRate: sampleRate),
            FileManager.default.fileExists(atPath: encoded.path)
        {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [wav.path, url.path, "-f", "m4af", "-d", "aac"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw FileImportError.invalidAudio("Could not encode a synthetic m4a fixture")
        }
    }

    private static func encodeM4A(fromWAV wav: URL, to destination: URL, sampleRate: Int) throws -> URL {
        let input = try AVAudioFile(forReading: wav)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        let frames = AVAudioFrameCount(input.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: max(frames, 1)) else {
            throw FileImportError.invalidAudio("m4a buffer")
        }
        try input.read(into: buffer)
        if buffer.frameLength > 0 {
            try output.write(from: buffer)
        }
        return destination
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}
