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

    @Test func startedWatcherIsReleasedWhenNothingElseHoldsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-watch-lifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        weak var released: InboxWatcher?
        do {
            let watcher = InboxWatcher(directory: directory, pollInterval: 60)
            watcher.start()
            released = watcher
            #expect(released != nil)
        }

        for _ in 0..<100 where released != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(released == nil)
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

        let words = merged.flatMap { $0.text.split(separator: " ").map(String.init) }
        #expect(words.filter { $0 == "yes" }.count == 2)
        #expect(words.filter { $0 == "next" }.count == 1)
        #expect(Set(merged.compactMap(\.speakerTag)).count == 2)
    }

    @Test func overlapDeduperTrimsSeamWordTimingsWithTheText() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(
                    start: 564,
                    end: 570,
                    text: "I agree with",
                    words: [
                        Word(text: "I agree", start: 564, end: 567),
                        Word(text: "with", start: 567, end: 570),
                    ],
                    channel: .mixed
                ),
            ],
            incoming: [
                RawSegment(start: 0, end: 3, text: "with that plan", channel: .mixed),
            ],
            incomingOffset: 565
        )

        #expect(merged.map(\.text) == ["I agree", "with that plan"])
        #expect(merged.first?.words?.map(\.text) == ["I agree"])

        let turns = TurnAttributor.attributeMono(segments: merged, clusters: [], profiles: [])
        #expect(turns.map(\.text).joined(separator: " ") == "I agree with that plan")
        #expect(zip(turns, turns.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func overlapDeduperKeepsResegmentedSeamSpeechInChronologicalOrder() {
        let merged = ImportTranscriptOverlapDeduper.merge(
            previous: [
                RawSegment(start: 564, end: 570, text: "I agree with", channel: .mixed),
            ],
            incoming: [
                RawSegment(start: 0, end: 3, text: "with that plan", channel: .mixed),
                RawSegment(start: 3, end: 5, text: "and more", channel: .mixed),
            ],
            incomingOffset: 565
        )

        #expect(merged.map(\.text).joined(separator: " ") == "I agree with that plan and more")
        #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(merged.allSatisfy { $0.start <= $0.end })
        #expect(merged.last?.end == 570)
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

    /// A run that failed in the notes stage never claimed the content, so the
    /// retry that finishes it must not be rejected as a duplicate of itself and
    /// take the transcript the first run produced down with it.
    @Test func retryAfterANotesFailureIsNotADuplicateOfItself() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-notes-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("call.wav")
        try ImportFixtureWriter.writeWAV(to: file, seconds: 0.3)

        let store = MemoryStore()
        let duplicates = InboxDuplicateIndex()
        let callID = UUID()
        let notesBody = CallNotes(title: "Pilot ship", summary: "Ship the pilot next week.")
        func pipeline(notesAreUsable: Bool) -> ImportPipeline {
            let health: ProviderHealth = notesAreUsable ? .healthy : .unavailable(reason: "ollama is down")
            return ImportPipeline(
                store: store,
                spine: FileTranscriptionSpine(
                    speech: ScriptedPCMTranscriber(
                        near: [RawSegment(start: 0, end: 1, text: "We will ship the pilot next week.", channel: .mixed)],
                        far: []
                    ),
                    diarizer: ScriptedDiarizer(clusters: []),
                    store: store
                ),
                notes: NotesGenerationSpine(
                    instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
                    deep: ScriptedNotesProvider(id: .glimmer, health: health, outputs: [.success(notesBody)]),
                    fallback: ScriptedNotesProvider(id: .fallbackInstruct, health: health, outputs: [.success(notesBody)]),
                    store: store
                ),
                duplicates: duplicates,
                audioRoot: root.appendingPathComponent("audio", isDirectory: true)
            )
        }
        func job() -> ImportJob {
            ImportJob(fileName: file.lastPathComponent, sourceURL: file, callID: callID)
        }

        await #expect(throws: Error.self) {
            try await pipeline(notesAreUsable: false).`import`(file, engine: .appleSpeech, job: job())
        }
        let transcribed = try await store.fetchSegments(callID: callID, provider: .appleSpeech)
        #expect(!transcribed.isEmpty)

        let processed = try await pipeline(notesAreUsable: true).`import`(file, engine: .appleSpeech, job: job())

        #expect(processed.call.id == callID)
        #expect(processed.call.status == .notesReady)
        #expect(try await store.fetchCalls().count == 1)
        #expect(try await store.fetchSegments(callID: callID, provider: .appleSpeech).map(\.text) == transcribed.map(\.text))
        #expect(FileManager.default.fileExists(atPath: processed.call.audioPath))
    }

    /// A phone upload reaches the pipeline with its Call row already written by
    /// `MacSyncServer.storeAccepted`, so an existing Call must not exempt the
    /// first processing attempt from the content-hash check.
    @Test func phoneUploadOfAlreadyImportedBytesIsADuplicate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("call.wav")
        try ImportFixtureWriter.writeWAV(to: file, seconds: 0.3)

        let store = MemoryStore()
        let duplicates = InboxDuplicateIndex()
        let notesBody = CallNotes(title: "Pilot ship", summary: "Ship the pilot next week.")
        func pipeline() -> ImportPipeline {
            ImportPipeline(
                store: store,
                spine: FileTranscriptionSpine(
                    speech: ScriptedPCMTranscriber(
                        near: [RawSegment(start: 0, end: 1, text: "We will ship the pilot next week.", channel: .mixed)],
                        far: []
                    ),
                    diarizer: ScriptedDiarizer(clusters: []),
                    store: store
                ),
                notes: NotesGenerationSpine(
                    instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
                    deep: ScriptedNotesProvider(id: .glimmer, health: .healthy, outputs: [.success(notesBody)]),
                    fallback: ScriptedNotesProvider(id: .fallbackInstruct, health: .healthy, outputs: [.success(notesBody)]),
                    store: store
                ),
                duplicates: duplicates,
                audioRoot: root.appendingPathComponent("audio", isDirectory: true)
            )
        }

        let imported = try await pipeline().`import`(
            file,
            engine: .appleSpeech,
            job: ImportJob(fileName: file.lastPathComponent, sourceURL: file, callID: UUID())
        )
        #expect(imported.call.status == .notesReady)

        // What MacSyncServer.storeAccepted does before it hands the staged audio
        // to the pipeline: the Call row exists with no segments yet.
        let uploadID = UUID()
        try await store.upsertCall(
            Call(
                id: uploadID,
                source: .iphoneRecording,
                startedAt: Date(),
                audioPath: file.path,
                sttProvider: .appleSpeech,
                status: .uploaded
            )
        )

        await #expect(throws: FileImportError.duplicate) {
            try await pipeline().`import`(
                file,
                engine: .appleSpeech,
                source: .iphoneRecording,
                job: ImportJob(fileName: file.lastPathComponent, sourceURL: file, callID: uploadID)
            )
        }
        #expect(try await store.fetchSegments(callID: uploadID, provider: .appleSpeech).isEmpty)
    }

    /// Notes failing after transcription still claims the content hash, so a
    /// later drop of the same inbox file (a new call ID) is a duplicate.
    @Test func notesFailureStillRejectsASecondInboxDropOfTheSameBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-notes-fail-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("call.wav")
        try ImportFixtureWriter.writeWAV(to: file, seconds: 0.3)

        let store = MemoryStore()
        let duplicates = InboxDuplicateIndex()
        func pipeline() -> ImportPipeline {
            ImportPipeline(
                store: store,
                spine: FileTranscriptionSpine(
                    speech: ScriptedPCMTranscriber(
                        near: [RawSegment(start: 0, end: 1, text: "We will ship the pilot next week.", channel: .mixed)],
                        far: []
                    ),
                    diarizer: ScriptedDiarizer(clusters: []),
                    store: store
                ),
                notes: NotesGenerationSpine(
                    instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
                    deep: ScriptedNotesProvider(id: .glimmer, health: .unavailable(reason: "ollama is down"), outputs: []),
                    fallback: ScriptedNotesProvider(id: .fallbackInstruct, health: .unavailable(reason: "ollama is down"), outputs: []),
                    store: store
                ),
                duplicates: duplicates,
                audioRoot: root.appendingPathComponent("audio", isDirectory: true)
            )
        }

        await #expect(throws: Error.self) {
            try await pipeline().`import`(file, engine: .appleSpeech, job: ImportJob(fileName: file.lastPathComponent, sourceURL: file, callID: UUID()))
        }
        await #expect(throws: FileImportError.duplicate) {
            try await pipeline().`import`(file, engine: .appleSpeech, job: ImportJob(fileName: file.lastPathComponent, sourceURL: file, callID: UUID()))
        }
        #expect(try await store.fetchCalls().count == 1)
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
        #expect(persisted?.errorStage == "transcription")
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
        #expect(persisted?.errorStage == "transcription")
    }

    @Test func metaImportKeepsProviderSpeakersWhenLocalDiarizationIsEmpty() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-meta-tags-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 32_000), sampleRate: 16_000, to: url)
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
                segments: [
                    RawSegment(start: 0, end: 1, text: "Morning.", speakerTag: "speaker_0", channel: .mixed),
                    RawSegment(start: 2, end: 3, text: "Morning to you.", speakerTag: "speaker_1", channel: .mixed),
                ],
                billedSeconds: 1
            )
        )

        let processed = try await spine.process(fileURL: url, call: call, profiles: [])

        #expect(processed.turns.map(\.text) == ["Morning.", "Morning to you."])
        #expect(Set(processed.turns.map(\.speakerName)).count == 2)

        let reloaded = TurnAttributor.fromStored(
            segments: try await store.fetchSegments(callID: call.id, provider: .metaMuse),
            speakers: try await store.fetchCallSpeakers(callID: call.id),
            profiles: []
        )
        #expect(reloaded.map(\.speakerName) == processed.turns.map(\.speakerName))
        #expect(Set(reloaded.map(\.speakerName)).count == 2)
    }

    @Test func unassignedImportSpeakerLabelSurvivesAReload() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-unassigned-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 16_000 * 2 * 12), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech,
            status: .uploaded
        )
        let speech = ScriptedPCMTranscriber(
            near: [
                RawSegment(start: 0, end: 5, text: "Inside the cluster.", channel: .mixed),
                RawSegment(start: 8, end: 11, text: "Outside every cluster.", channel: .mixed),
            ],
            far: []
        )
        let spine = FileTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: [
                DiarizedCluster(
                    key: "A",
                    ranges: [0...5],
                    embedding: [0, 0, 1],
                    embeddingModel: EmbeddingModel.weSpeakerV2
                )
            ]),
            store: store
        )
        let owner = SpeakerProfile(
            displayName: "Me",
            isOwner: true,
            centroid: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertSpeakerProfile(owner)

        let processed = try await spine.process(fileURL: url, call: call, profiles: [owner])
        #expect(processed.turns.map(\.speakerName) == ["Speaker 2", "Speaker 3"])

        let reloaded = TurnAttributor.fromStored(
            segments: try await store.fetchSegments(callID: call.id, provider: .appleSpeech),
            speakers: try await store.fetchCallSpeakers(callID: call.id),
            profiles: [owner]
        )
        #expect(reloaded.map(\.speakerName) == ["Speaker 2", "Speaker 3"])
    }

    @Test func chunkProgressNeverDropsBelowThePipelineFraction() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-progress-floor-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 16_000 * 601 * 2), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let ticks = LockBox<[ImportJob]>([])
        var spine = FileTranscriptionSpine(
            speech: ScriptedPCMTranscriber(
                near: [RawSegment(start: 0, end: 1, text: "Chunk speech.", channel: .mixed)],
                far: []
            ),
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        )
        spine.onProgress = { job in ticks.value.append(job) }

        _ = try await spine.process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .appleSpeech),
            profiles: [],
            job: ImportJob(
                fileName: "drop.caf",
                sourceURL: url,
                stage: .transcribing,
                fractionComplete: 0.1
            )
        )

        #expect(ticks.value.allSatisfy { $0.fractionComplete >= 0.1 })
        #expect(zip(ticks.value, ticks.value.dropFirst()).allSatisfy { $0.fractionComplete <= $1.fractionComplete })
    }

    @Test func stereoImportProgressNeverGoesBackward() async throws {
        let store = MemoryStore()
        let channel = Data(count: 16_000 * 601 * 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-stereo-progress-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(near: channel, far: channel, sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let ticks = LockBox<[ImportJob]>([])
        var spine = FileTranscriptionSpine(
            speech: ScriptedPCMTranscriber(
                near: [RawSegment(start: 0, end: 1, text: "Near speech.", channel: .near)],
                far: [RawSegment(start: 0, end: 1, text: "Far speech.", channel: .far)]
            ),
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        )
        spine.onProgress = { job in ticks.value.append(job) }

        _ = try await spine.process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .appleSpeech),
            profiles: []
        )

        let transcribing = ticks.value.filter { $0.stage == .transcribing }
        #expect(transcribing.map(\.chunkCount).max() == 4)
        #expect(transcribing.map(\.chunkIndex).max() == 3)
        #expect(zip(transcribing, transcribing.dropFirst()).allSatisfy { $0.chunkIndex <= $1.chunkIndex })
        #expect(zip(transcribing, transcribing.dropFirst()).allSatisfy { $0.fractionComplete <= $1.fractionComplete })
        #expect(transcribing.contains { $0.statusLine.contains("chunk 4 of 4") })
    }

    @Test func captureStereoCAFKeepsNearAndFarChannels() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-capture-stereo-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 16_000 * 2 * 2),
            far: Data(count: 16_000 * 2 * 2),
            sampleRate: 16_000,
            to: url
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let speech = ChannelRecordingTranscriber()
        let owner = SpeakerProfile(
            displayName: "Me",
            isOwner: true,
            centroid: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )

        let processed = try await FileTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        ).process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .appleSpeech),
            profiles: [owner]
        )

        #expect(speech.channels.value == [.near, .far])
        #expect(Set(processed.turns.map(\.channel)) == [.near, .far])
        #expect(processed.turns.filter { $0.channel == .near }.allSatisfy { $0.speakerID == owner.id })
    }

    @Test func unmarkedStereoCAFIsTreatedAsUnknownRoomAudio() async throws {
        let marked = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-marked-\(UUID().uuidString).caf")
        let unmarked = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-unmarked-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: marked)
            try? FileManager.default.removeItem(at: unmarked)
        }
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 16_000 * 2),
            far: Data(count: 16_000 * 2),
            sampleRate: 16_000,
            to: marked
        )
        try ImportFixtureWriter.writeConstantStereoCAF(to: unmarked, seconds: 0.5, sampleRate: 16_000)

        #expect(CaptureChannelMarker.hasNearFarMarker(marked))
        #expect(!CaptureChannelMarker.hasNearFarMarker(unmarked))
        #expect(try FileAudioLoader.load(marked).layout == .captureNearFar)
        #expect(try FileAudioLoader.load(unmarked).layout == .unknownStereo)

        let speech = ChannelRecordingTranscriber()
        _ = try await FileTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: []),
            store: MemoryStore()
        ).process(
            fileURL: unmarked,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: unmarked.path, sttProvider: .appleSpeech),
            profiles: []
        )
        #expect(speech.channels.value == [.mixed])
    }

    @Test func captureWriterStampsTheLayoutItRecorded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-capture-writer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try StereoCAFWriter(url: url)
        try writer.write(
            near: [Int16](repeating: 1_000, count: 8_000),
            far: [Int16](repeating: -1_000, count: 8_000)
        )
        #expect(!CaptureChannelMarker.hasNearFarMarker(url))
        writer.close()

        #expect(CaptureChannelMarker.hasNearFarMarker(url))
        let loaded = try FileAudioLoader.load(url)
        #expect(loaded.layout == .captureNearFar)
        #expect(loaded.isStereo)
        #expect(try StereoCAFReader.read(url).near.count == 8_000)
    }

    @Test func unknownStereoFileIsDownmixedAndDiarizedInsteadOfSplit() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-unknown-stereo-\(UUID().uuidString).wav")
        try ImportFixtureWriter.writeConstantStereoWAV(
            to: url,
            seconds: 2,
            sampleRate: 16_000,
            near: 0.5,
            far: 0.5
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let speech = ChannelRecordingTranscriber()
        let owner = SpeakerProfile(
            displayName: "Me",
            isOwner: true,
            centroid: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )

        let processed = try await FileTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: [
                DiarizedCluster(
                    key: "A",
                    ranges: [0...2],
                    embedding: [0, 0, 1],
                    embeddingModel: EmbeddingModel.weSpeakerV2
                )
            ]),
            store: store
        ).process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .appleSpeech),
            profiles: [owner]
        )

        #expect(speech.channels.value == [.mixed])
        #expect(processed.turns.map(\.channel) == [.mixed])
        #expect(processed.turns.allSatisfy { $0.speakerID != owner.id })
        #expect(processed.turns.map(\.clusterKey) == ["A"])
    }

    @Test func wholeChunkProviderStillProducesChunkedAttributedTurns() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-wholechunk-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 16_000 * 601 * 2), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .fluidParakeet
        )

        let processed = try await FileTranscriptionSpine(
            speech: WholeChunkTranscriber(),
            diarizer: ScriptedDiarizer(clusters: [
                DiarizedCluster(
                    key: "A",
                    ranges: [0...400],
                    embedding: [0, 0, 1],
                    embeddingModel: EmbeddingModel.weSpeakerV2
                ),
                DiarizedCluster(
                    key: "B",
                    ranges: [401...601],
                    embedding: [0, 1, 0],
                    embeddingModel: EmbeddingModel.weSpeakerV2
                ),
            ]),
            store: store
        ).process(fileURL: url, call: call, profiles: [])

        #expect(processed.turns.count == 2)
        #expect(processed.turns.map(\.clusterKey) == ["A", "B"])
        #expect(Set(processed.turns.map(\.speakerName)).count == 2)
        let stored = try await store.fetchSegments(callID: call.id, provider: .fluidParakeet)
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.clusterKey != nil })
    }

    @Test func importProgressStageNeverRegressesToTranscribing() async throws {
        let store = MemoryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-stage-order-\(UUID().uuidString).caf")
        try ChannelAudio.writeMonoCAF(pcm16: Data(count: 16_000 * 2 * 2), sampleRate: 16_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let ticks = LockBox<[ImportJob]>([])
        var spine = FileTranscriptionSpine(
            speech: ScriptedPCMTranscriber(
                near: [RawSegment(start: 0, end: 1, text: "One turn.", channel: .mixed)],
                far: []
            ),
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        )
        spine.onProgress = { job in ticks.value.append(job) }

        _ = try await spine.process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .appleSpeech),
            profiles: []
        )

        let stages = ticks.value.map(\.stage)
        #expect(stages.contains(.stitching))
        #expect(!stages.drop(while: { $0 != .stitching }).contains(.transcribing))
        #expect(ticks.value.last?.fractionComplete == 0.9)
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
    @Test func unknownStereoIsTranscribedFromTheDownmixNotTheLeftChannel() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-apple-stereo-\(UUID().uuidString).wav")
        try ImportFixtureWriter.writeConstantStereoWAV(
            to: url,
            seconds: 0.5,
            sampleRate: 16_000,
            near: 0,
            far: 0.5
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = LockBox<[Int]>([])

        let segments = try await AppleSpeechProvider().transcribeFile(
            fileURL: url,
            config: STTSessionConfig(sampleRate: 16_000)
        ) { pcm16, channel, _ in
            let samples = pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            peaks.value.append(samples.reduce(0) { max($0, abs(Int($1))) })
            return [RawSegment(start: 0, end: 1, text: "Both channels.", channel: channel)]
        }

        #expect(segments.map(\.channel) == [.mixed])
        #expect(peaks.value.count == 1)
        #expect(abs((peaks.value.first ?? 0) - 8_192) <= 2)
    }

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

    @Test func multiBatchStereoSourceResamplesBothChannelsWithoutGaps() throws {
        let seconds = FileAudioLoader.decodeBatchSeconds * 2.5
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-stereo-batches-\(UUID().uuidString).wav")
        try ImportFixtureWriter.writeConstantStereoWAV(
            to: url,
            seconds: seconds,
            sampleRate: 44_100,
            near: 0.5,
            far: -0.25
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try FileAudioLoader.load(url)
        let mixedSamples = samples(of: loaded.mixed)
        let expectedFrames = Int(seconds * 16_000)

        #expect(loaded.channelCount == 2)
        #expect(loaded.layout == .unknownStereo)
        #expect(!loaded.isStereo)
        #expect(loaded.far.isEmpty)
        #expect(abs(mixedSamples.count - expectedFrames) <= 2)
        #expect(mixedSamples.allSatisfy { abs(Int($0) - 4_096) <= 2 })
        #expect(abs(loaded.duration - seconds) < 0.01)
    }

    @Test func multichannelImportKeepsCentreChannelSpeech() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-surround-\(UUID().uuidString).caf")
        try ImportFixtureWriter.writeCentreChannelSurroundCAF(to: url, seconds: 1, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try FileAudioLoader.load(url)
        let mixedSamples = samples(of: loaded.mixed)

        #expect(loaded.channelCount == 6)
        #expect(loaded.layout == .unknownStereo)
        #expect(mixedSamples.count == 16_000)
        #expect(mixedSamples.allSatisfy { abs(Int($0) - 3_277) <= 2 })

        let speech = ChannelRecordingTranscriber()
        _ = try await FileTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: []),
            store: MemoryStore()
        ).process(
            fileURL: url,
            call: Call(source: .fileImport, startedAt: Date(), audioPath: url.path, sttProvider: .appleSpeech),
            profiles: []
        )
        #expect(speech.channels.value == [.mixed])
        #expect(speech.peaks.value.allSatisfy { $0 > 3_000 })
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

    private func samples(of pcm16: Data) -> [Int16] {
        pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
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

private final class ChannelRecordingTranscriber: PCMTranscriber, @unchecked Sendable {
    let id: STTProviderID = .appleSpeech
    let dualInstanceMode: DualInstanceMode = .nearLiveFarBatch
    let channels = LockBox<[SegmentChannel]>([])
    let peaks = LockBox<[Int]>([])

    func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment] {
        channels.value.append(channel)
        let samples = pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        peaks.value.append(samples.reduce(0) { max($0, abs(Int($1))) })
        return [RawSegment(start: 0, end: 1, text: "Speech on \(channel.rawValue).", channel: channel)]
    }
}

private struct WholeChunkTranscriber: PCMTranscriber {
    let id: STTProviderID = .fluidParakeet
    let dualInstanceMode: DualInstanceMode = .nearLiveFarBatch

    func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment] {
        let duration = Double(pcm16.count / 2) / Double(config.sampleRate)
        return [
            RawSegment(
                start: 0,
                end: duration,
                text: "One unsegmented chunk of \(Int(duration)) seconds.",
                channel: channel
            )
        ]
    }
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

    static func writeConstantStereoWAV(
        to url: URL,
        seconds: Double,
        sampleRate: Int,
        near: Float,
        far: Float
    ) throws {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ),
            let channels = buffer.floatChannelData
        else {
            throw FileImportError.invalidAudio("Could not build a stereo fixture buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            channels[0][index] = near
            channels[1][index] = far
        }
        try file.write(from: buffer)
    }

    static func writeCentreChannelSurroundCAF(to url: URL, seconds: Double, sampleRate: Int) throws {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        guard let channelLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) else {
            throw FileImportError.invalidAudio("Could not build a 5.1 fixture layout")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channelLayout: channelLayout)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let channels = buffer.floatChannelData
        else {
            throw FileImportError.invalidAudio("Could not build a 5.1 fixture buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            channels[2][index] = 0.6
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func writeConstantStereoCAF(to url: URL, seconds: Double, sampleRate: Int) throws {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 2,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let channels = buffer.floatChannelData
        else {
            throw FileImportError.invalidAudio("Could not build an unmarked CAF fixture")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            channels[0][index] = 0.25
            channels[1][index] = -0.25
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
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
