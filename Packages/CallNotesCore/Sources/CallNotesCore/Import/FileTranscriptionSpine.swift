import Foundation

/// Batch transcription for imported files. Apple, Parakeet, and Meta all go
/// through the same 9.5-minute / 5-second-overlap chunk plan, then stitch.
public struct FileTranscriptionSpine: Sendable {
    public var speech: any PCMTranscriber
    public var diarizer: any DiarizationService
    public var store: any CallStore
    public var meta: (any MetaFileTranscribing)?
    public var onProgress: (@Sendable (ImportJob) -> Void)?

    public init(
        speech: any PCMTranscriber,
        diarizer: any DiarizationService,
        store: any CallStore,
        meta: (any MetaFileTranscribing)? = nil,
        onProgress: (@Sendable (ImportJob) -> Void)? = nil
    ) {
        self.speech = speech
        self.diarizer = diarizer
        self.store = store
        self.meta = meta
        self.onProgress = onProgress
    }

    public func process(
        fileURL: URL,
        call: Call,
        profiles: [SpeakerProfile],
        job: ImportJob = ImportJob(fileName: "", sourceURL: URL(fileURLWithPath: "/"))
    ) async throws -> ProcessedCall {
        var working = call
        var progress = job
        let metaBilling = MetaImportBilling()
        working.status = .transcribing
        working.audioPath = fileURL.path
        try await store.upsertCall(working)

        var stage = "audio_load"
        do {
            if working.sttProvider == .metaMuse, let meta {
                return try await processMeta(
                    fileURL: fileURL,
                    call: working,
                    profiles: profiles,
                    job: progress,
                    meta: meta,
                    billing: metaBilling,
                    stage: &stage
                )
            }

            let loaded = try FileAudioLoader.load(fileURL)
            working.sampleRate = loaded.sampleRate
            working.audioChannels = loaded.channelCount
            working.durationSec = Int(loaded.duration.rounded(.down))
            working.endedAt = working.startedAt.addingTimeInterval(loaded.duration)
            working.sttProvider = speech.id
            working.diarizationProvider = diarizer.providerID
            try await store.upsertCall(working)

            stage = "transcription"
            progress.stage = .transcribing
            emit(progress)

            let config = STTSessionConfig(sampleRate: loaded.sampleRate)
            let nearPlans = ImportFileChunker.plan(
                totalFrames: loaded.near.count / 2,
                sampleRate: loaded.sampleRate
            )
            let farPlans = loaded.isStereo
                ? ImportFileChunker.plan(totalFrames: loaded.far.count / 2, sampleRate: loaded.sampleRate)
                : []
            progress.chunkCount = nearPlans.count + farPlans.count
            let raw: [RawSegment]
            if loaded.isStereo {
                let near = try await transcribeChunked(
                    pcm: loaded.near,
                    plans: nearPlans,
                    channel: .near,
                    sampleRate: loaded.sampleRate,
                    config: config,
                    job: &progress,
                    completedChunks: 0
                )
                let far = try await transcribeChunked(
                    pcm: loaded.far,
                    plans: farPlans,
                    channel: .far,
                    sampleRate: loaded.sampleRate,
                    config: config,
                    job: &progress,
                    completedChunks: nearPlans.count
                )
                raw = (near + far).sorted { $0.start < $1.start }
            } else {
                raw = try await transcribeChunked(
                    pcm: loaded.near,
                    plans: nearPlans,
                    channel: .mixed,
                    sampleRate: loaded.sampleRate,
                    config: config,
                    job: &progress,
                    completedChunks: 0
                )
            }
            guard !raw.isEmpty else { throw FileImportError.emptyTranscript }

            stage = "stitching"
            progress.stage = .stitching
            progress.fractionComplete = 0.85
            emit(progress)

            let diarizePCM = loaded.isStereo ? loaded.far : loaded.near
            let farURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(working.id.uuidString)-import-diarize.caf")
            defer { try? FileManager.default.removeItem(at: farURL) }
            stage = "diarization"
            try ChannelAudio.writeMonoCAF(pcm16: diarizePCM, sampleRate: Double(loaded.sampleRate), to: farURL)
            let clusters = try await diarizer.diarize(fileURL: farURL)

            stage = "attribution"
            let turns: [AttributedTurn]
            if loaded.isStereo {
                turns = TurnAttributor.attribute(
                    near: raw.filter { $0.channel == .near },
                    far: raw.filter { $0.channel == .far },
                    clusters: clusters,
                    profiles: profiles
                )
            } else {
                turns = TurnAttributor.attributeMono(segments: raw, clusters: clusters, profiles: profiles)
            }

            let segments = TurnAttributor.toSegments(turns, callID: working.id, provider: speech.id)
            stage = "persistence"
            try await store.replaceSegments(callID: working.id, provider: speech.id, segments)
            let mappings = TurnAttributor.callSpeakers(
                for: turns,
                clusters: clusters,
                callID: working.id
            )
            try await store.replaceCallSpeakers(callID: working.id, speakers: mappings)

            working.status = .transcribed
            working.error = nil
            working.errorStage = nil
            try await store.upsertCall(working)

            progress.stage = .transcribing
            progress.fractionComplete = 0.9
            emit(progress)

            return ProcessedCall(
                call: working,
                turns: turns,
                clusters: clusters,
                dualInstanceMode: speech.dualInstanceMode
            )
        } catch {
            if let metaFailure = error as? MetaFileTranscriptionFailure {
                await metaBilling.add(metaFailure.billedSeconds)
            }
            working.metaBilledSec += await metaBilling.value
            working.status = .failed
            working.error = error.localizedDescription
            working.errorStage = stage
            working.endedAt = working.endedAt ?? Date()
            try? await store.upsertCall(working)
            throw error
        }
    }

    private func processMeta(
        fileURL: URL,
        call: Call,
        profiles: [SpeakerProfile],
        job: ImportJob,
        meta: any MetaFileTranscribing,
        billing: MetaImportBilling,
        stage: inout String
    ) async throws -> ProcessedCall {
        var working = call
        var progress = job
        progress.stage = .transcribing
        emit(progress)
        stage = "transcription"
        let result = try await meta.transcribeWithReceipt(fileURL: fileURL, config: STTSessionConfig())
        await billing.add(result.billedSeconds)
        working.metaBilledSec += result.billedSeconds
        working.sttProvider = .metaMuse
        guard !result.segments.isEmpty else { throw FileImportError.emptyTranscript }

        progress.stage = .stitching
        progress.fractionComplete = 0.85
        emit(progress)

        let loaded = try? FileAudioLoader.load(fileURL)
        if let loaded {
            working.sampleRate = loaded.sampleRate
            working.audioChannels = loaded.channelCount
            working.durationSec = Int(loaded.duration.rounded(.down))
            working.endedAt = working.startedAt.addingTimeInterval(loaded.duration)
        }

        stage = "diarization"
        let diarizeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(working.id.uuidString)-meta-diarize.caf")
        defer { try? FileManager.default.removeItem(at: diarizeURL) }
        if let loaded {
            try ChannelAudio.writeMonoCAF(
                pcm16: loaded.mixed,
                sampleRate: Double(loaded.sampleRate),
                to: diarizeURL
            )
        }
        let clusters: [DiarizedCluster]
        if FileManager.default.fileExists(atPath: diarizeURL.path) {
            clusters = (try? await diarizer.diarize(fileURL: diarizeURL)) ?? []
        } else {
            clusters = []
        }
        working.diarizationProvider = diarizer.providerID

        stage = "attribution"
        let localSegments = result.segments.map { segment -> RawSegment in
            var segment = segment
            segment.speakerTag = ClusterAssigner.assign(segment: segment, clusters: clusters)
                ?? segment.speakerTag
            return segment
        }
        let turns = TurnAttributor.attributeMono(
            segments: localSegments,
            clusters: clusters,
            profiles: profiles
        )
        let segments = TurnAttributor.toSegments(turns, callID: working.id, provider: .metaMuse)
        stage = "persistence"
        try await store.replaceSegments(callID: working.id, provider: .metaMuse, segments)
        let mappings = TurnAttributor.callSpeakers(
            for: turns,
            clusters: clusters,
            callID: working.id
        )
        try await store.replaceCallSpeakers(callID: working.id, speakers: mappings)
        working.status = .transcribed
        working.error = nil
        working.errorStage = nil
        try await store.upsertCall(working)
        return ProcessedCall(
            call: working,
            turns: turns,
            clusters: clusters,
            dualInstanceMode: .nearLiveFarBatch
        )
    }

    private func transcribeChunked(
        pcm: Data,
        plans: [ImportFileChunk],
        channel: SegmentChannel,
        sampleRate: Int,
        config: STTSessionConfig,
        job: inout ImportJob,
        completedChunks: Int
    ) async throws -> [RawSegment] {
        job.chunkCount = max(job.chunkCount, completedChunks + plans.count)
        var merged: [RawSegment] = []
        for (index, chunk) in plans.enumerated() {
            job.chunkIndex = completedChunks + index
            job.stage = .transcribing
            job.fractionComplete = Double(job.chunkIndex) / Double(max(job.chunkCount, 1)) * 0.8
            emit(job)
            let slice = try ImportFileChunker.pcmSlice(pcm, chunk: chunk)
            let relative = try await speech.transcribePCM(slice, channel: channel, config: config)
            let offset = Double(chunk.startFrame) / Double(sampleRate)
            merged = ImportTranscriptOverlapDeduper.merge(
                previous: merged,
                incoming: relative.map { segment in
                    var copy = segment
                    copy.channel = channel
                    return copy
                },
                incomingOffset: offset
            )
        }
        return merged
    }

    private func emit(_ job: ImportJob) {
        onProgress?(job)
    }
}

private actor MetaImportBilling {
    private var seconds = 0

    func add(_ seconds: Int) {
        self.seconds += seconds
    }

    var value: Int { seconds }
}
