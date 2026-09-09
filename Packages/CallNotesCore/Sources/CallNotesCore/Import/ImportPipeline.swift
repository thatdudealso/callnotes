import Foundation

/// Copies a settled inbox file into the audio store, transcribes it with the
/// selected engine, and runs the same notes spine as live calls.
public struct ImportPipeline: Sendable {
    public var store: any CallStore
    public var spine: FileTranscriptionSpine
    public var notes: NotesGenerationSpine?
    public var duplicates: InboxDuplicateIndex
    /// Tests inject a temp folder so imports never touch Application Support.
    public var audioRoot: URL?
    public var onProgress: (@Sendable (ImportJob) -> Void)?

    public init(
        store: any CallStore,
        spine: FileTranscriptionSpine,
        notes: NotesGenerationSpine? = nil,
        duplicates: InboxDuplicateIndex,
        audioRoot: URL? = nil,
        onProgress: (@Sendable (ImportJob) -> Void)? = nil
    ) {
        self.store = store
        self.spine = spine
        self.notes = notes
        self.duplicates = duplicates
        self.audioRoot = audioRoot
        self.onProgress = onProgress
    }

    public func `import`(
        _ url: URL,
        engine: STTProviderID,
        source: CallSource = .fileImport,
        counterpartyName: String? = nil,
        job: ImportJob? = nil
    ) async throws -> ProcessedCall {
        var progress = job ?? ImportJob(fileName: url.lastPathComponent, sourceURL: url)
        progress.fileName = url.lastPathComponent
        progress.sourceURL = url

        let hash = try await duplicates.fingerprint(of: url)
        if await duplicates.contains(hash) {
            progress.stage = .duplicate
            progress.fractionComplete = 1
            emit(progress)
            throw FileImportError.duplicate
        }

        progress.stage = .copying
        progress.fractionComplete = 0.05
        emit(progress)

        let callID = progress.callID ?? UUID()
        let storedURL = try storedAudioURL(callID: callID, sourceExtension: url.pathExtension)
        if FileManager.default.fileExists(atPath: storedURL.path) {
            try FileManager.default.removeItem(at: storedURL)
        }
        try FileManager.default.copyItem(at: url, to: storedURL)

        var call = Call(
            id: callID,
            source: source,
            startedAt: Date(),
            counterpartyName: counterpartyName,
            audioPath: storedURL.path,
            audioChannels: 1,
            sttProvider: engine,
            status: .transcribing
        )
        try await store.upsertCall(call)
        progress.callID = callID
        progress.stage = .transcribing
        progress.fractionComplete = 0.1
        emit(progress)

        let profiles = try await store.fetchSpeakerProfiles()
        var reportingSpine = spine
        let fileName = url.lastPathComponent
        reportingSpine.onProgress = { update in
            var merged = update
            merged.callID = callID
            merged.fileName = fileName
            merged.sourceURL = url
            self.emit(merged)
        }
        let processed = try await reportingSpine.process(
            fileURL: storedURL,
            call: call,
            profiles: profiles,
            job: progress
        )
        call = processed.call
        _ = await duplicates.register(hash)

        if let notes {
            progress.stage = .notes
            progress.fractionComplete = 0.92
            emit(progress)
            let transcript = Transcript(
                callID: call.id,
                turns: processed.turns,
                provider: call.sttProvider,
                counterpartyName: call.counterpartyName
            )
            _ = try await notes.generateInstant(transcript, call: call)
            let deep = try await notes.generateDeep(transcript, call: call)
            var finished = processed
            if let stored = try await store.fetchCall(id: call.id) {
                finished.call = stored
            } else {
                finished.call.notesProvider = deep.provider
                finished.call.status = .notesReady
            }
            progress.stage = .completed
            progress.fractionComplete = 1
            emit(progress)
            return finished
        }

        progress.stage = .completed
        progress.fractionComplete = 1
        emit(progress)
        return processed
    }

    private func storedAudioURL(callID: UUID, sourceExtension: String) throws -> URL {
        if let audioRoot {
            try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
            let ext = sourceExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let resolved = ext.isEmpty ? "caf" : ext
            return audioRoot.appendingPathComponent("\(callID.uuidString).\(resolved)")
        }
        return try CallAudioPaths.importedAudioURL(
            callID: callID,
            sourceExtension: sourceExtension
        )
    }

    private func emit(_ job: ImportJob) {
        onProgress?(job)
    }
}
