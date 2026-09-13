import AppKit
import CallNotesCore
import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case dashboard
    case call(UUID)
}

@MainActor
@Observable
final class AppModel {
    var recordingState: RecordingState = .idle {
        didSet { updateDashboardTicker() }
    }
    var calls: [Call] = []
    var selectedCallID: UUID?
    var turnsByCall: [UUID: [AttributedTurn]] = [:]
    var live: LiveTranscriptState = LiveTranscriptState()
    var storeBackendName = "initializing"
    var isStoreInitialized = false
    var lastDER: DiarizationErrorRate.Result?
    var lastDERCallID: UUID?
    var statusMessage: String?
    var notesByCall: [UUID: NotesRecord] = [:]
    var notesGeneratingCallID: UUID?
    var importProgress = ImportProgress()
    var inboxURL: URL?
    var dashboardAnalytics = DashboardAnalytics.make(from: [])

    private var store: any CallStore
    private var notesSpine: NotesGenerationSpine?
    private var speech = AppleSpeechProvider()
    private let memoryStore = MemoryStore()
    private var liveSession: (any STTSession)?
    private var liveResultsTask: Task<Void, Never>?
    private var liveSegments: [RawSegment] = []
    private var liveTranscriptionFailure: String?
    private var instantCallAtHangUp: Call?
    private var captureStopHandler: (@MainActor () async -> URL?)?
    private var isStartingLiveSession = false
    private var isProcessingSample = false
    private var inboxWatcher: InboxWatcher?
    private var importDuplicates: InboxDuplicateIndex?
    private var pendingInboxFiles: [URL] = []
    private var isImporting = false
    private var importNoticeTask: Task<Void, Never>?
    private var showsDashboard = false
    private var dashboardObservationTask: Task<Void, Never>?
    private var dashboardTickerTask: Task<Void, Never>?

    /// The sidebar owns navigation, but the model owns the state so a closed and
    /// reopened window lands back on the Dashboard or the call the user was reading.
    var sidebarSelection: SidebarItem? {
        get {
            if showsDashboard { return .dashboard }
            return selectedCallID.map(SidebarItem.call)
        }
        set {
            switch newValue {
            case .dashboard:
                showsDashboard = true
            case .call(let id):
                showsDashboard = false
                selectedCallID = id
                if let call = calls.first(where: { $0.id == id }) {
                    Task { [weak self] in
                        await self?.select(call)
                    }
                }
            case nil:
                break
            }
        }
    }

    private var syncServerTask: Task<Void, Never>?
    private var syncBonjourService: NetService?
    private var syncServer: MacSyncServer?
    private var syncIdentity: MacTLSIdentity?
    private var syncActivity: NSObjectProtocol?
    var pairingQRPayload: String?
    var pairedDevices: [PairedDevice] = []
    var unsavedRevocations: [UUID: String] = [:]

    var liveCallID: UUID? { instantCallAtHangUp?.id }

    var selectedCall: Call? {
        calls.first { $0.id == selectedCallID }
    }

    var selectedTurns: [AttributedTurn] {
        guard let selectedCallID else { return [] }
        return turnsByCall[selectedCallID] ?? []
    }

    var selectedNotes: NotesRecord? {
        guard let selectedCallID else { return nil }
        return notesByCall[selectedCallID]
    }

    var isGeneratingNotes: Bool {
        selectedCallID != nil && selectedCallID == notesGeneratingCallID
    }

    var metaBilledSeconds: Int {
        calls.reduce(0) { $0 + $1.metaBilledSec }
    }

    var metaBilledDuration: String {
        let minutes = metaBilledSeconds / 60
        let seconds = metaBilledSeconds % 60
        return "\(minutes)m \(seconds)s"
    }

    var metaCost: String {
        MetaCostMeter.costDollars(billedSeconds: metaBilledSeconds)
            .formatted(.currency(code: "USD"))
    }

    var canProcessSampleCall: Bool {
        isStoreInitialized
            && storeBackendName == "postgres"
            && recordingState == .idle
            && liveSession == nil
            && !isStartingLiveSession
            && !isProcessingSample
    }

    var canStartLiveSession: Bool {
        isStoreInitialized
            && recordingState == .idle
            && liveSession == nil
            && !isStartingLiveSession
            && !isProcessingSample
    }

    init() {
        self.store = memoryStore
        statusMessage = "Checking dedicated CallNotes Postgres..."
        observeDashboardChanges()
        Task { await bootstrap() }
    }

    func bootstrap() async {
        guard let postgres = await PostgresStore.makeIfAvailable() else {
            storeBackendName = "unavailable"
            isStoreInitialized = true
            statusMessage = "Dedicated CallNotes Postgres is unavailable. Load sample call is disabled."
            return
        }
        do {
            try await postgres.migrate()
        } catch {
            store = memoryStore
            storeBackendName = "unavailable"
            isStoreInitialized = true
            statusMessage = "Dedicated CallNotes Postgres is unavailable: \(error.localizedDescription). Load sample call is disabled."
            return
        }
        statusMessage = "Validating Apple SpeechAnalyzer dual-instance support..."
        speech = await AppleSpeechProvider.validated()
        live.dualInstanceMode = speech.dualInstanceMode
        // The repair reads every `.recording` row, so it has to finish before
        // `postgres` becomes the published store: a call started while it is in
        // flight would otherwise land in the table it is about to close out.
        var repairFailure: String?
        var recovered: [RecoveredRecording] = []
        do {
            if let audioDir = try? CallAudioPaths.audioDirectory() {
                recovered = try await PartialRecordingRecovery.recover(
                    audioDirectory: audioDir,
                    store: postgres
                )
            }
            _ = try await postgres.closeStrandedRecordings(excluding: instantCallAtHangUp?.id)
        } catch {
            repairFailure = error.localizedDescription
        }
        store = postgres
        storeBackendName = "postgres"
        isStoreInitialized = true
        observeDashboardChanges()
        notesSpine = NotesGenerationSpine(client: OllamaClient(), store: postgres)
        startSyncServer(store: postgres)
        statusMessage = repairFailure
        startInboxWatcher()
        let recoveredIDs = recovered.map(\.call.id)
        Task { await self.processRecoveredRecordings(ids: recoveredIDs) }
        Task { _ = await self.sweepRetention() }
        logDiagnostic(category: "bootstrap", event: "store_ready", metadata: [
            "backend": "postgres",
            "recovered": String(recovered.count),
        ])
    }

    func refresh() async throws {
        dashboardAnalytics = try await store.fetchDashboardAnalytics(asOf: .now)
        calls = dashboardAnalytics.calls.map(\.call)
        if selectedCallID == nil {
            selectedCallID = calls.first?.id
        }
        guard !showsDashboard else { return }
        notesByCall = try await store.fetchPreferredNotesByCall()
        if let selectedCallID {
            turnsByCall[selectedCallID] = try await loadTurns(callID: selectedCallID)
        }
    }

    /// Processing one call writes its row several times. The store keeps only the
    /// newest pending change and this window lets a burst settle, so a single write
    /// never fans out into one refresh per store write.
    private static let dashboardRefreshSettle = Duration.milliseconds(250)

    private func observeDashboardChanges() {
        dashboardObservationTask?.cancel()
        let observedStore = store
        dashboardObservationTask = Task { [weak self] in
            let changes = await observedStore.dashboardChanges()
            guard !Task.isCancelled, let self else { return }
            await self.refreshReportingFailure()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.dashboardRefreshSettle)
                guard !Task.isCancelled else { return }
                await self.refreshReportingFailure()
            }
        }
    }

    private func refreshReportingFailure() async {
        do {
            try await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startSyncServer(store: any CallStore) {
        guard syncServerTask == nil else { return }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(CallAudioPaths.applicationSupportFolder, isDirectory: true)
            let syncDirectory = support.appendingPathComponent("Sync", isDirectory: true)
            let identity = try MacTLSIdentity(storageDirectory: syncDirectory)
            let pairing = PairingAuthority(persistenceURL: syncDirectory.appendingPathComponent("paired-devices.json"))
            let uploads = support.appendingPathComponent("PhoneUploads", isDirectory: true)
            let server = MacSyncServer(
                pairing: pairing,
                store: store,
                receivedUploadsDirectory: uploads,
                onAccepted: { [weak self] callID, audioURL, metadata in
                    try await self?.processPhoneUpload(callID: callID, audioURL: audioURL, metadata: metadata)
                }
            )
            let service = NetService(domain: "local.", type: "\(SyncConstants.bonjourServiceType).", name: Host.current().localizedName ?? "CallNotes", port: Int32(SyncConstants.serverPort))
            service.publish()
            syncBonjourService = service
            syncServer = server
            syncIdentity = identity
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "CallNotes phone sync")
            syncActivity = activity
            syncServerTask = Task {
                defer { ProcessInfo.processInfo.endActivity(activity) }
                do { try await server.run(host: "0.0.0.0", identity: identity) }
                catch { self.statusMessage = "Phone sync stopped: \(error.localizedDescription)" }
            }
            Task { await refreshPairingTicket() }
        } catch {
            statusMessage = "Phone sync unavailable: \(error.localizedDescription)"
        }
    }

    func refreshPairingTicket() async {
        guard let server = syncServer, let identity = syncIdentity else { return }
        let host = (Host.current().name ?? "localhost").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let serverURL = URL(string: "https://\(host):\(SyncConstants.serverPort)") else { return }
        let ticket = await server.pairingTicket(serverURL: serverURL, identity: identity)
        pairingQRPayload = try? ticket.qrPayload()
        await refreshPairedDevices(from: server)
    }

    /// A revoke that could not be written is blocked in memory but comes back on
    /// the next launch, so the pane the user acted in has to say so. Which ones
    /// are still at risk is the authority's to answer: a phone pairing over
    /// `POST /pair` writes the same whole-device snapshot without passing
    /// through here, and that write makes an earlier failed revocation durable.
    func revokePairedDevice(_ id: UUID) async {
        guard let server = syncServer else { return }
        do {
            try await server.revoke(deviceID: id)
        } catch {
            statusMessage = error.localizedDescription
            unsavedRevocations[id] = error.localizedDescription
        }
        await refreshPairedDevices(from: server)
    }

    private func refreshPairedDevices(from server: MacSyncServer) async {
        pairedDevices = await server.pairedDevices()
        let stillUnsaved = await server.unsavedRevocationIDs()
        unsavedRevocations = unsavedRevocations.filter { stillUnsaved.contains($0.key) }
    }

    /// The content-hash index is what keeps a re-shared recording from becoming a
    /// second call, so it is resolved from Application Support here rather than
    /// as a side effect of the inbox watcher, which the phone path never starts.
    /// An index that cannot be persisted is reported, never silently substituted.
    private func resolvedImportDuplicates() -> InboxDuplicateIndex {
        if let importDuplicates { return importDuplicates }
        do {
            let index = InboxDuplicateIndex(storageURL: try InboxPaths.seenIndexURL())
            importDuplicates = index
            return index
        } catch {
            statusMessage = "Duplicate recordings cannot be detected: \(error.localizedDescription)"
            return InboxDuplicateIndex()
        }
    }

    /// The one owner of which engine an import runs on. Both the inbox and the
    /// phone-upload path go through here so the rule cannot drift between them.
    private func makeImportPipeline() async -> (ImportPipeline, STTProviderID) {
        let storedDefault = UserDefaults.standard.string(forKey: "default_engine")
        let configuredDefault: STTProviderID? = storedDefault == "meta" ? .metaMuse : .appleSpeech
        var meta: (any MetaFileTranscribing)?
        if EngineSelection.resolve(override: nil, configuredDefault: configuredDefault) == .metaMuse {
            do {
                meta = MetaFileProvider(configuration: try metaConfiguration())
            } catch {
                statusMessage = "Meta is not configured. Importing with local transcription."
            }
        }
        let engine = EngineSelection.resolveImport(
            configuredDefault: configuredDefault,
            metaIsConfigured: meta != nil,
            parakeetIsUsable: await FluidParakeetProvider().healthCheck().isUsable
        )
        if engine != .metaMuse { meta = nil }
        let speech: any PCMTranscriber = engine == .fluidParakeet ? FluidParakeetProvider() : self.speech
        let pipeline = ImportPipeline(
            store: store,
            spine: FileTranscriptionSpine(
                speech: speech,
                diarizer: FluidDiarizer(),
                store: store,
                meta: meta
            ),
            notes: notesSpine,
            duplicates: resolvedImportDuplicates(),
            onProgress: { [weak self] update in
                Task { @MainActor in
                    self?.upsertImportJob(update)
                }
            }
        )
        return (pipeline, engine)
    }

    func processPhoneUpload(callID: UUID, audioURL: URL, metadata: CallUploadMetadata) async throws {
        guard isStoreInitialized else { return }
        if let fallbackTranscript = metadata.fallbackTranscript {
            try await persistFallbackTranscript(fallbackTranscript, for: callID)
            if try await resumeNotes(callID: callID, audioURL: audioURL) {
                removePhoneUploadStaging(audioURL)
                try await refresh()
                statusMessage = "Imported iPhone fallback transcript."
                return
            }
        }
        if try await resumeNotes(callID: callID, audioURL: audioURL) { return }
        var job = ImportJob(fileName: audioURL.lastPathComponent, sourceURL: audioURL, stage: .settling, callID: callID)
        upsertImportJob(job)
        let (pipeline, engine) = await makeImportPipeline()
        do {
            let processed = try await pipeline.`import`(
                audioURL,
                engine: engine,
                source: metadata.source,
                counterpartyName: metadata.counterpartyName,
                startedAt: metadata.startedAt,
                job: job
            )
            job.callID = processed.call.id
            job.stage = .completed
            job.fractionComplete = 1
            upsertImportJob(job)
            turnsByCall[processed.call.id] = processed.turns
            selectedCallID = processed.call.id
            removePhoneUploadStaging(audioURL)
            try await refresh()
            statusMessage = "Imported iPhone recording."
        } catch FileImportError.duplicate {
            try? await store.deleteCall(id: callID)
            removePhoneUploadStaging(audioURL)
            job.stage = .duplicate
            job.fractionComplete = 1
            upsertImportJob(job)
        } catch {
            job.stage = .failed
            job.error = error.localizedDescription
            upsertImportJob(job)
            statusMessage = error.localizedDescription
            throw error
        }
    }

    private func persistFallbackTranscript(_ transcript: OnDeviceFallbackTranscript, for callID: UUID) async throws {
        guard var call = try await store.fetchCall(id: callID) else { return }
        let segments = transcript.segments.enumerated().map { index, raw in
            Segment(
                callID: callID,
                seq: index,
                startSec: raw.start,
                endSec: raw.end,
                channel: raw.channel ?? .mixed,
                clusterKey: raw.channel?.rawValue,
                text: raw.text,
                provider: transcript.provider
            )
        }
        guard !segments.isEmpty else { return }
        try await store.replaceSegments(callID: callID, provider: transcript.provider, segments)
        call.sttProvider = transcript.provider
        call.status = .transcribed
        call.error = nil
        call.errorStage = nil
        try await store.upsertCall(call)
    }

    /// A retried upload whose transcript already landed only needs its notes.
    /// Re-importing the same bytes would fingerprint the recording as a
    /// duplicate of itself and delete the call this retry exists to finish.
    private func resumeNotes(callID: UUID, audioURL: URL) async throws -> Bool {
        guard let notesSpine, let call = try await store.fetchCall(id: callID) else { return false }
        let segments = try await store.fetchSegments(callID: callID, provider: call.sttProvider)
        guard !segments.isEmpty else { return false }
        let speakers = try await store.fetchCallSpeakers(callID: callID)
        let profiles = try await store.fetchSpeakerProfiles()
        let turns = TurnAttributor.fromStored(segments: segments, speakers: speakers, profiles: profiles)
        var job = ImportJob(fileName: audioURL.lastPathComponent, sourceURL: audioURL, stage: .notes, callID: callID)
        job.fractionComplete = 0.92
        upsertImportJob(job)
        let transcript = Transcript(
            callID: callID,
            turns: turns,
            provider: call.sttProvider,
            counterpartyName: call.counterpartyName
        )
        do {
            _ = try await notesSpine.generateInstant(transcript, call: call)
            _ = try await notesSpine.generateDeep(transcript, call: call)
        } catch {
            await persistNotesFailure(callID: callID, error: error)
            job.stage = .failed
            job.error = error.localizedDescription
            upsertImportJob(job)
            statusMessage = error.localizedDescription
            throw error
        }
        job.stage = .completed
        job.fractionComplete = 1
        upsertImportJob(job)
        turnsByCall[callID] = turns
        selectedCallID = callID
        removePhoneUploadStaging(audioURL)
        try await refresh()
        statusMessage = "Finished notes for iPhone recording."
        return true
    }

    private func removePhoneUploadStaging(_ audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: CallUploadMetadata.sidecarURL(nextTo: audioURL))
    }

    private func persistNotesFailure(callID: UUID, error: Error) async {
        guard var call = try? await store.fetchCall(id: callID) else { return }
        call.status = .failed
        call.error = error.localizedDescription
        call.errorStage = PipelineStage.notes.rawValue
        try? await store.upsertCall(call)
    }

    private func updateDashboardTicker() {
        guard recordingState == .recording else {
            dashboardTickerTask?.cancel()
            dashboardTickerTask = nil
            return
        }
        guard dashboardTickerTask == nil else { return }
        dashboardTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.recordingState == .recording else { return }
                guard let liveCallID = self.instantCallAtHangUp?.id else { continue }
                self.dashboardAnalytics = self.dashboardAnalytics.updatingLiveDuration(for: liveCallID)
            }
        }
    }

    func select(_ call: Call) async {
        selectedCallID = call.id
        do {
            turnsByCall[call.id] = try await loadTurns(callID: call.id)
            notesByCall[call.id] = try await store.fetchPreferredNotes(callID: call.id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func processSampleCall() async {
        guard canProcessSampleCall else {
            statusMessage = isStoreInitialized
                ? "Dedicated CallNotes Postgres is unavailable. Load sample call is disabled."
                : "Waiting for dedicated CallNotes Postgres and SpeechAnalyzer validation before loading the sample call..."
            return
        }
        isProcessingSample = true
        defer {
            isProcessingSample = false
            if recordingState == .processing {
                recordingState = .idle
            }
        }
        recordingState = .processing
        statusMessage = "Processing sample call..."
        live.lastLine = "Processing sample call..."

        do {
            let fixture = try SampleCallFixture.materialize()
            let call = Call(
                source: .fileImport,
                startedAt: Date(),
                counterpartyName: "Priya",
                audioPath: fixture.cafURL.path,
                sttProvider: .appleSpeech,
                status: .transcribing
            )
            try await store.upsertCall(call)
            instantCallAtHangUp = nil
            instantCallAtHangUp = call
            try await startLiveSession(forSamplePlayback: true, override: .appleSpeech)
            try await playFixture(cafURL: fixture.cafURL)
            let diarizer = FluidDiarizer()
            let priyaEmbedding = try await SampleCallFixture.priyaEmbedding(
                cafURL: fixture.cafURL,
                diarizer: diarizer
            )
            var profiles = try await store.fetchSpeakerProfiles()
            if !profiles.contains(where: \.isOwner) {
                let owner = SpeakerIdentity.enroll(
                    displayName: "Me",
                    isOwner: true,
                    embedding: SampleCallFixture.embedding([1, 0, 0]),
                    embeddingModel: EmbeddingModel.weSpeakerV2
                )
                try await store.upsertSpeakerProfile(owner)
                profiles.append(owner)
            }
            if let index = profiles.firstIndex(where: {
                $0.contactIdentifier == SampleCallFixture.priyaContactIdentifier
            }) {
                var priya = profiles[index]
                priya.displayName = "Priya"
                priya.centroid = priyaEmbedding
                priya.embeddingModel = diarizer.embeddingModelID()
                priya.sampleCount = max(priya.sampleCount, 1)
                try await store.upsertSpeakerProfile(priya)
                profiles[index] = priya
            } else {
                let priya = SpeakerIdentity.enroll(
                    displayName: "Priya",
                    contactIdentifier: SampleCallFixture.priyaContactIdentifier,
                    embedding: priyaEmbedding,
                    embeddingModel: diarizer.embeddingModelID()
                )
                try await store.upsertSpeakerProfile(priya)
                profiles.append(priya)
            }

            let processed = try await processWithLocalEngine(
                cafURL: fixture.cafURL,
                call: call,
                profiles: profiles,
                diarizer: diarizer
            )

            turnsByCall[processed.call.id] = processed.turns
            lastDER = processed.der
            lastDERCallID = processed.call.id
            live.engine = .appleSpeech
            live.elapsed = TimeInterval(processed.call.durationSec ?? 0)
            live.currentSpeakerName = processed.turns.last?.speakerName ?? "Me"
            if live.lastLine.isEmpty || live.lastLine == "Processing sample call..." {
                live.lastLine = processed.turns.last?.text ?? ""
            }
            live.isProvisionalSpeaker = false
            live.dualInstanceMode = processed.dualInstanceMode
            selectedCallID = processed.call.id
            try await refresh()
            await generateDeepNotes(for: processed)
            let derText: String
            if let der = processed.der {
                derText = String(format: "DER %.1f%% (target %.1f%%)", der.der * 100, DiarizationErrorRate.initialTarget * 100)
            } else {
                derText = "DER not scored"
            }
            statusMessage = "Sample call stored in \(storeBackendName). \(derText)"
        } catch {
            instantCallAtHangUp = nil
            statusMessage = error.localizedDescription
            recordingState = .idle
        }
    }

    func startLiveSession(
        forSamplePlayback: Bool = false,
        override perCallOverride: STTProviderID? = nil
    ) async throws {
        guard liveSession == nil,
            !isStartingLiveSession,
            recordingState == .idle || (forSamplePlayback && isProcessingSample)
        else {
            return
        }
        isStartingLiveSession = true
        do {
            let provider = try await configuredProvider(override: perCallOverride)
            let session = try await provider.provider.startSession(config: STTSessionConfig())
            let engine = session is AppleSpeechSession ? STTProviderID.appleSpeech : provider.requestedID
            liveSession = session
            liveSegments = []
            liveTranscriptionFailure = nil
            live.engine = engine
            live.isOffDevice = engine == .metaMuse
            if !forSamplePlayback {
                let counterpartyName = await suggestedCounterpartyName()
                let callID = UUID()
                let audioPath = (try? CallAudioPaths.cafURL(callID: callID).path) ?? ""
                let call = Call(
                    id: callID,
                    source: .macManual,
                    startedAt: Date(),
                    counterpartyName: counterpartyName,
                    audioPath: audioPath,
                    sttProvider: engine,
                    status: .recording
                )
                try await store.upsertCall(call)
                instantCallAtHangUp = call
            }
            recordingState = .recording
            liveResultsTask = Task { [weak self] in
                do {
                    for try await segment in session.results {
                        guard !Task.isCancelled, let self else { return }
                        if let fallback = session as? MetaFallbackSession, await fallback.isUsingFallback() {
                            live.engine = .appleSpeech
                            live.isOffDevice = false
                            statusMessage = "Meta became unavailable. Continuing with local transcription."
                        }
                        live.elapsed = max(live.elapsed, segment.end)
                        live.currentSpeakerName = segment.channel == .far ? "Speaker 2" : "Me"
                        live.lastLine = segment.text
                        live.isProvisionalSpeaker = segment.channel == .far || segment.isVolatile
                        if !segment.isVolatile {
                            retainFinalLiveSegment(segment)
                        }
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    liveTranscriptionFailure = error.localizedDescription
                    statusMessage = liveTranscriptionFailure
                }
            }
            isStartingLiveSession = false
        } catch {
            isStartingLiveSession = false
            instantCallAtHangUp = nil
            liveSegments = []
            throw error
        }
    }

    func appendLivePCM(_ pcm: Data) async throws {
        try await liveSession?.append(pcm: pcm)
    }

    func finishLiveSession(captureURL: URL? = nil) async {
        let finishedSession = liveSession
        defer {
            liveSession = nil
            liveResultsTask = nil
            recordingState = .idle
        }
        do {
            try await liveSession?.finish()
            await liveResultsTask?.value
        } catch {
            liveResultsTask?.cancel()
            liveTranscriptionFailure = error.localizedDescription
            statusMessage = liveTranscriptionFailure
        }
        if var call = instantCallAtHangUp {
            instantCallAtHangUp = nil
            let billedSeconds = await realtimeMetaBilledSeconds(for: finishedSession)
            call.metaBilledSec += billedSeconds
            call.endedAt = Date()
            call.durationSec = max(0, Int(call.endedAt!.timeIntervalSince(call.startedAt).rounded(.down)))
            if let captureURL {
                _ = try? CAFHeaderRepair.repairIfNeeded(captureURL)
                call.audioPath = captureURL.path
            } else if let surviving = survivingRecordingURL(for: call) {
                _ = try? CAFHeaderRepair.repairIfNeeded(surviving)
                call.audioPath = surviving.path
            }
            if let liveTranscriptionFailure {
                call.status = .failed
                call.error = liveTranscriptionFailure
                call.errorStage = PipelineStage.transcription.rawValue
            } else if captureURL != nil {
                call.status = .transcribed
            } else if survivingRecordingURL(for: call) != nil {
                call.status = .uploaded
            } else if call.source == .macManual {
                call.status = .failed
                call.error = "Audio capture did not produce a recording"
                call.errorStage = PipelineStage.capture.rawValue
            } else {
                call.status = .transcribed
            }
            if let session = finishedSession as? MetaFallbackSession, await session.isUsingFallback() {
                call.sttProvider = .appleSpeech
            }
            do {
                let segments = liveSegments.enumerated().map { index, raw in
                    Segment(
                        callID: call.id,
                        seq: index,
                        startSec: raw.start,
                        endSec: raw.end,
                        channel: raw.channel ?? .mixed,
                        clusterKey: raw.speakerTag,
                        text: raw.text,
                        words: raw.words,
                        provider: call.sttProvider
                    )
                }
                try await store.replaceSegments(callID: call.id, provider: call.sttProvider, segments)
                try await store.upsertCall(call)
            } catch {
                statusMessage = error.localizedDescription
                return
            }
            if call.status == .failed, call.errorStage == PipelineStage.transcription.rawValue {
                statusMessage = call.error
                return
            }
            guard call.status == .transcribed || call.status == .uploaded else {
                statusMessage = "Audio capture failed. The live transcript was kept without a recording."
                return
            }
            if call.status == .uploaded {
                statusMessage = "Capture ended with a partial recording. Processing it."
                await processSavedRecording(call)
                return
            }
            await generateInstantNotes(for: call, rawSegments: liveSegments)
        }
    }

    func stopLiveSession() async {
        let captureURL = await captureStopHandler?()
        await finishLiveSession(captureURL: captureURL)
    }

    func setCaptureStopHandler(_ handler: @escaping @MainActor () async -> URL?) {
        captureStopHandler = handler
    }

    func failLiveSessionForCapture(_ message: String) async {
        guard let session = liveSession else { return }
        let resultsTask = liveResultsTask
        liveSession = nil
        liveResultsTask = nil
        liveSegments = []
        resultsTask?.cancel()
        try? await session.finish()
        recordingState = .idle
        live.isOffDevice = false

        guard var call = instantCallAtHangUp else {
            statusMessage = "Audio capture could not start: \(message)"
            return
        }
        instantCallAtHangUp = nil
        call.endedAt = Date()
        call.durationSec = max(0, Int(call.endedAt!.timeIntervalSince(call.startedAt).rounded(.down)))
        call.status = .failed
        call.error = message
        call.errorStage = PipelineStage.capture.rawValue
        if let surviving = survivingRecordingURL(for: call) {
            _ = try? CAFHeaderRepair.repairIfNeeded(surviving)
            call.audioPath = surviving.path
            call.status = .uploaded
            call.error = nil
            call.errorStage = nil
        }
        do {
            try await store.upsertCall(call)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        if call.status == .uploaded {
            statusMessage = "Capture stopped early. The partial recording was kept."
            await processSavedRecording(call)
            return
        }
        statusMessage = "Audio capture could not start: \(message)"
    }

    func captureDidStart(callID: UUID, url: URL) async {
        if var call = instantCallAtHangUp {
            call.audioPath = url.path
            instantCallAtHangUp = call
            try? await store.upsertCall(call)
            return
        }
        let call = Call(
            id: callID,
            source: .macFaceTime,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech,
            status: .recording
        )
        try? await store.upsertCall(call)
        logDiagnostic(category: "capture", event: "started", metadata: ["call": callID.uuidString])
    }

    func updateCounterpartyName(for callID: UUID, name: String) async {
        guard let index = calls.firstIndex(where: { $0.id == callID }) else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        calls[index].counterpartyName = normalized.isEmpty ? nil : normalized
        let call = calls[index]
        if instantCallAtHangUp?.id == callID {
            instantCallAtHangUp = call
        }
        do {
            try await store.upsertCall(call)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func suggestedCounterpartyName() async -> String? {
        guard let profiles = try? await store.fetchSpeakerProfiles() else { return nil }
        let candidates = profiles.filter {
            !$0.isOwner && !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return candidates.count == 1 ? candidates[0].displayName : nil
    }

    private func retainFinalLiveSegment(_ candidate: RawSegment) {
        let normalized = candidate.text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard !liveSegments.contains(where: {
            $0.start < candidate.end && candidate.start < $0.end
                && $0.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined() == normalized
        }) else { return }
        liveSegments.append(candidate)
    }

    /// The detail view uses this for "Re-transcribe with...". A Meta file
    /// failure intentionally falls back to the local provider and leaves a
    /// non-blocking explanation rather than marking a captured call failed.
    func retranscribeSelectedCall(with provider: STTProviderID) async {
        guard var call = selectedCall else { return }
        statusMessage = "Transcribing with \(retranscribeLabel(provider))..."
        do {
            switch provider {
            case .metaMuse:
                let configuration = try metaConfiguration()
                let result = try await MetaFileProvider(configuration: configuration).transcribeWithReceipt(
                    fileURL: URL(fileURLWithPath: call.audioPath),
                    config: STTSessionConfig()
                )
                try await persistRetranscription(result.segments, provider: .metaMuse, call: &call)
                call.metaBilledSec += result.billedSeconds
                try await store.upsertCall(call)
                statusMessage = "Re-transcribed with Meta. \(result.billedSeconds)s billed."
            case .fluidParakeet:
                let processed = try await FileTranscriptionSpine(
                    speech: FluidParakeetProvider(),
                    diarizer: FluidDiarizer(),
                    store: store
                ).process(
                    fileURL: URL(fileURLWithPath: call.audioPath),
                    call: call,
                    profiles: try await store.fetchSpeakerProfiles()
                )
                call = processed.call
                turnsByCall[call.id] = processed.turns
                statusMessage = "Re-transcribed with Parakeet."
            case .appleSpeech:
                let segments = try await speech.transcribe(
                    fileURL: URL(fileURLWithPath: call.audioPath),
                    config: STTSessionConfig()
                )
                try await persistRetranscription(segments, provider: .appleSpeech, call: &call)
                statusMessage = "Re-transcribed locally."
            }
            await select(call)
        } catch {
            guard provider == .metaMuse else {
                statusMessage = error.localizedDescription
                return
            }
            if let partial = error as? MetaFileTranscriptionFailure, partial.billedSeconds > 0 {
                call.metaBilledSec += partial.billedSeconds
                do {
                    try await store.upsertCall(call)
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
            do {
                let segments = try await speech.transcribe(
                    fileURL: URL(fileURLWithPath: call.audioPath),
                    config: STTSessionConfig()
                )
                try await persistRetranscription(segments, provider: .appleSpeech, call: &call)
                await select(call)
                statusMessage = "Meta was unavailable. Re-transcribed locally instead."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func revealInbox() {
        let url = inboxURL ?? (try? InboxPaths.resolvedInbox())
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func startInboxWatcher() {
        guard isStoreInitialized else { return }
        inboxWatcher?.stop()
        do {
            let directory = try InboxPaths.resolvedInbox()
            inboxURL = directory
            _ = resolvedImportDuplicates()
            let iCloud = InboxPaths.iCloudDriveInbox()?.standardizedFileURL
            let source: CallSource =
                iCloud == directory.standardizedFileURL ? .iphoneRecording : .fileImport
            let watcher = InboxWatcher(directory: directory, sourceForDirectory: source)
            watcher.onSettled = { [weak self] url in
                Task { @MainActor in
                    await self?.enqueueInboxImport(url, source: source)
                }
            }
            inboxWatcher = watcher
            watcher.start()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func enqueueInboxImport(_ url: URL, source: CallSource) async {
        pendingInboxFiles.append(url)
        await drainInboxQueue(source: source)
    }

    private func drainInboxQueue(source: CallSource) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        while !pendingInboxFiles.isEmpty {
            let url = pendingInboxFiles.removeFirst()
            await importInboxFile(url, source: source)
        }
    }

    private func importInboxFile(_ url: URL, source: CallSource) async {
        guard isStoreInitialized else { return }
        var job = ImportJob(fileName: url.lastPathComponent, sourceURL: url, stage: .settling)
        upsertImportJob(job)
        let (pipeline, engine) = await makeImportPipeline()
        do {
            let processed = try await pipeline.`import`(url, engine: engine, source: source)
            job.callID = processed.call.id
            job.stage = .completed
            job.fractionComplete = 1
            upsertImportJob(job)
            turnsByCall[processed.call.id] = processed.turns
            selectedCallID = processed.call.id
            try await refresh()
            statusMessage = "Imported \(url.lastPathComponent)."
        } catch FileImportError.duplicate {
            job.stage = .duplicate
            job.fractionComplete = 1
            upsertImportJob(job)
        } catch {
            job.stage = .failed
            job.error = error.localizedDescription
            upsertImportJob(job)
            statusMessage = error.localizedDescription
        }
    }

    private func upsertImportJob(_ job: ImportJob) {
        importProgress.upsert(job)
        guard job.stage.isTerminal else { return }
        importNoticeTask?.cancel()
        importNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ImportProgress.completedNoticeSeconds))
            guard !Task.isCancelled else { return }
            self?.importProgress.prune()
        }
    }

    func dismissImportJob(_ jobID: UUID) {
        importProgress.dismiss(jobID)
    }

    private func retranscribeLabel(_ provider: STTProviderID) -> String {
        switch provider {
        case .appleSpeech: "Local"
        case .fluidParakeet: "Parakeet"
        case .metaMuse: "Meta"
        }
    }

    private func playFixture(cafURL: URL) async throws {
        do {
            let split = try ChannelAudio.splitStereoCAF(url: cafURL)
            let chunkSize = 8_000
            for offset in stride(from: 0, to: split.near.count, by: chunkSize) {
                let end = min(offset + chunkSize, split.near.count)
                try await appendLivePCM(split.near.subdata(in: offset..<end))
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await finishLiveSession()
            throw error
        }
        await finishLiveSession()
    }

    private func processWithLocalEngine(
        cafURL: URL,
        call: Call,
        profiles: [SpeakerProfile],
        diarizer: FluidDiarizer
    ) async throws -> ProcessedCall {
        let spine = LocalTranscriptionSpine(
            speech: speech,
            diarizer: diarizer,
            store: store
        )
        guard let priyaProfileID = profiles.first(where: {
            $0.contactIdentifier == SampleCallFixture.priyaContactIdentifier
        })?.id else {
            throw SampleCallError.missingPriyaProfile
        }
        let processed = try await spine.process(
            cafURL: cafURL,
            call: call,
            profiles: profiles,
            referenceTurns: SampleCallFixture.referenceTurns,
            requiredFarSpeakerID: priyaProfileID
        )
        return processed
    }

    private func configuredProvider(
        override perCallOverride: STTProviderID?
    ) async throws -> (provider: any STTProvider, requestedID: STTProviderID) {
        let storedDefault = UserDefaults.standard.string(forKey: "default_engine")
        let configuredDefault: STTProviderID? = storedDefault == "meta" ? .metaMuse : .appleSpeech
        let requestedID = EngineSelection.resolve(
            override: perCallOverride,
            configuredDefault: configuredDefault
        )
        guard requestedID == .metaMuse else { return (speech, .appleSpeech) }
        do {
            let profiles = try await store.fetchSpeakerProfiles()
            let diarizer = FluidDiarizer()
            let stitching = MetaRealtimeSpeakerStitching(profiles: profiles) { pcm in
                let samples = PCMResampler.resampleMono(
                    input: MetaPCMResampler.samples(from: pcm),
                    inputSampleRate: Double(MetaAudioFormat.pcm24KHz.sampleRate)
                )
                return try await diarizer.enrollEmbedding(samples: samples)
            }
            let meta = MetaRealtimeProvider(
                configuration: try metaConfiguration(),
                speakerStitching: stitching
            )
            return (MetaFallbackProvider(meta: meta, local: speech), .metaMuse)
        } catch {
            statusMessage = "Meta is not configured. Continuing with local transcription."
            return (speech, .appleSpeech)
        }
    }

    private func realtimeMetaBilledSeconds(for session: (any STTSession)?) async -> Int {
        if let session = session as? MetaFallbackSession {
            return await session.billedSeconds()
        }
        if let session = session as? MetaRealtimeSession {
            return await session.billedSeconds()
        }
        return 0
    }

    private func metaConfiguration() throws -> MetaTranscriptionConfiguration {
        guard let key = try MetaAPIKeyKeychain.load(), !key.isEmpty else {
            throw MetaTranscriptionError.missingAPIKey
        }
        return MetaTranscriptionConfiguration(
            apiKey: key,
            zeroDataRetention: UserDefaults.standard.object(forKey: "meta_zdr_enabled") as? Bool ?? true
        )
    }

    private func persistRetranscription(
        _ rawSegments: [RawSegment],
        provider: STTProviderID,
        call: inout Call
    ) async throws {
        let segments = rawSegments.enumerated().map { index, raw in
            Segment(
                callID: call.id,
                seq: index,
                startSec: raw.start,
                endSec: raw.end,
                channel: raw.channel ?? .mixed,
                clusterKey: raw.speakerTag,
                text: raw.text,
                words: raw.words,
                provider: provider
            )
        }
        try await store.replaceSegments(callID: call.id, provider: provider, segments)
        call.sttProvider = provider
        call.status = .transcribed
        call.error = nil
        call.errorStage = nil
        try await store.upsertCall(call)
    }

    func regenerateNotes() async {
        guard let call = selectedCall, let notesSpine else { return }
        let transcript = Transcript(
            callID: call.id,
            turns: selectedTurns,
            provider: call.sttProvider,
            counterpartyName: call.counterpartyName
        )
        notesGeneratingCallID = call.id
        statusMessage = "Notes generating..."
        defer {
            if notesGeneratingCallID == call.id { notesGeneratingCallID = nil }
        }
        do {
            let record = try await notesSpine.regenerate(transcript, call: call)
            notesByCall[call.id] = record
            try await refresh()
            statusMessage = "Notes regenerated (\(record.provider.rawValue))."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func notesMarkdown(for callID: UUID) -> String? {
        notesByCall[callID].map { NotesMarkdown.render($0.body) }
    }

    private func generateInstantNotes(for call: Call, rawSegments: [RawSegment]) async {
        guard let notesSpine else { return }
        let transcript = Transcript(
            callID: call.id,
            segments: rawSegments.enumerated().map { index, segment in
                Segment(
                    callID: call.id,
                    seq: index,
                    startSec: segment.start,
                    endSec: segment.end,
                    channel: segment.channel ?? .near,
                    clusterKey: segment.channel == .far ? "far" : "near",
                    text: segment.text,
                    provider: call.sttProvider
                )
            },
            speakerNames: ["near": "Me", "far": call.counterpartyName ?? "Speaker 2"],
            counterpartyName: call.counterpartyName
        )
        let instant: NotesRecord
        do {
            instant = try await notesSpine.generateInstant(transcript, call: call)
        } catch {
            await persistNotesFailure(callID: call.id, error: error)
            statusMessage = error.localizedDescription
            return
        }
        notesByCall[call.id] = instant
        selectedCallID = call.id
        do {
            try await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func generateDeepNotes(for processed: ProcessedCall) async {
        guard let notesSpine else { return }
        let transcript = Transcript(
            callID: processed.call.id,
            turns: processed.turns,
            provider: processed.call.sttProvider,
            counterpartyName: processed.call.counterpartyName
        )
        let callID = processed.call.id
        notesGeneratingCallID = callID
        statusMessage = "Notes generating..."
        Task { [notesSpine] in
            defer {
                if notesGeneratingCallID == callID { notesGeneratingCallID = nil }
            }
            let deep: NotesRecord
            do {
                deep = try await notesSpine.generateDeep(transcript, call: processed.call)
            } catch {
                await persistNotesFailure(callID: callID, error: error)
                statusMessage = error.localizedDescription
                return
            }
            notesByCall[callID] = deep
            do {
                try await refresh()
                statusMessage = "Notes ready (\(deep.provider.rawValue))."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func retryFailedStage() async {
        guard let call = selectedCall else { return }
        let hasAudio = survivingRecordingURL(for: call) != nil
        let presentation = FailurePresentation.make(
            error: call.error,
            errorStage: call.errorStage,
            hasAudio: hasAudio
        )
        switch presentation.action {
        case .recoverPartial, .retranscribe:
            await processSavedRecording(call)
        case .retryPersistence:
            await retryPersistence(for: call)
        case .regenerateNotes:
            await regenerateNotes()
        case .none:
            statusMessage = presentation.detail
        }
    }

    func sweepRetention() async -> RetentionSweepResult? {
        let storedDays = UserDefaults.standard.object(forKey: RetentionPolicy.daysDefaultsKey) as? Int
        let policy = RetentionPolicy.resolved(
            mode: UserDefaults.standard.string(forKey: RetentionPolicy.modeDefaultsKey),
            days: storedDays
        )
        do {
            let result = try await RetentionSweeper(policy: policy).sweep(store: store)
            if result.didReclaimDisk {
                try await refresh()
            }
            logDiagnostic(category: "retention", event: "swept", metadata: [
                "mode": policy.mode.rawValue,
                "bytes": String(result.reclaimedBytes),
            ])
            return result
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func backupDatabase(verify: Bool) async -> String {
        guard let paths = PostgresBackup.dedicatedPaths() else {
            return "Dedicated CallNotes Postgres was not found."
        }
        do {
            let backups = try supportRoot().appendingPathComponent("backups", isDirectory: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let dumpURL = backups.appendingPathComponent("callnotes-\(stamp).dump")
            if verify {
                _ = try PostgresBackup.backup(to: dumpURL, paths: paths, verify: true)
                return "Backup verified. Restore reproduced the live row counts. File: \(dumpURL.path)"
            }
            _ = try PostgresBackup.backup(to: dumpURL, paths: paths, verify: false)
            return "Wrote \(dumpURL.path)"
        } catch {
            return error.localizedDescription
        }
    }

    func exportDiagnostics(to directory: URL) async -> String {
        do {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let bundleDir = directory.appendingPathComponent("CallNotes-diagnostics-\(stamp)", isDirectory: true)
            let root = try supportRoot()
            let snapshot = DiagnosticsSnapshot(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                storeBackend: storeBackendName,
                engineDefault: UserDefaults.standard.string(forKey: "default_engine") ?? "local",
                consentPolicy: UserDefaults.standard.string(forKey: ConsentPolicy.defaultsKey) ?? ConsentPolicy.announce.rawValue,
                retention: RetentionPolicy.resolved(
                    mode: UserDefaults.standard.string(forKey: RetentionPolicy.modeDefaultsKey),
                    days: UserDefaults.standard.object(forKey: RetentionPolicy.daysDefaultsKey) as? Int
                ).mode.rawValue,
                dualInstanceMode: live.dualInstanceMode.rawValue,
                health: [
                    "postgres": storeBackendName,
                    "speech": speech.dualInstanceMode.rawValue,
                ],
                logLines: (try? DiagnosticLog.recentEvents(root: root)) ?? []
            )
            _ = try DiagnosticsBundle.export(snapshot, to: bundleDir)
            if let forbidden = DiagnosticsBundle.containsForbiddenContent(in: bundleDir) {
                return "Export blocked: \(forbidden)"
            }
            return "Exported \(bundleDir.path). Excludes \(DiagnosticsBundle.exclusions.joined(separator: ", "))."
        } catch {
            return error.localizedDescription
        }
    }

    private func processRecoveredRecordings(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let call = try? await store.fetchCall(id: id), call.status == .uploaded else { continue }
            await processSavedRecording(call)
        }
    }

    private func processSavedRecording(_ call: Call) async {
        guard let url = survivingRecordingURL(for: call) else {
            statusMessage = "No recording file was found to process."
            return
        }
        _ = try? CAFHeaderRepair.repairIfNeeded(url)
        statusMessage = "Processing saved recording..."
        recordingState = .processing
        defer {
            if recordingState == .processing { recordingState = .idle }
        }
        do {
            var working = call
            working.audioPath = url.path
            working.status = .transcribing
            working.error = nil
            working.errorStage = nil
            try await store.upsertCall(working)
            let processed = try await LocalTranscriptionSpine(
                speech: speech,
                diarizer: FluidDiarizer(),
                store: store
            ).process(
                cafURL: url,
                call: working,
                profiles: try await store.fetchSpeakerProfiles()
            )
            turnsByCall[processed.call.id] = processed.turns
            selectedCallID = processed.call.id
            try await refresh()
            await generateDeepNotes(for: processed)
            statusMessage = "Processed saved recording."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func retryPersistence(for failedCall: Call) async {
        await processSavedRecording(failedCall)
    }

    private func survivingRecordingURL(for call: Call) -> URL? {
        let candidates = [
            call.audioPath.isEmpty ? nil : URL(fileURLWithPath: call.audioPath),
            try? CallAudioPaths.cafURL(callID: call.id),
        ].compactMap { $0 }
        for url in candidates where PartialRecordingRecovery.hasProcessableAudio(path: url.path) {
            return url.resolvingSymlinksInPath()
        }
        return nil
    }

    private func supportRoot() throws -> URL {
        try CallAudioPaths.audioDirectory().deletingLastPathComponent()
    }

    private func logDiagnostic(category: String, event: String, metadata: [String: String] = [:]) {
        guard let root = try? supportRoot() else { return }
        try? DiagnosticLog.append(
            DiagnosticEvent(category: category, event: event, metadata: metadata),
            root: root
        )
    }

    private func loadTurns(callID: UUID) async throws -> [AttributedTurn] {
        let provider = calls.first { $0.id == callID }?.sttProvider
        let segments = try await store.fetchSegments(callID: callID, provider: provider)
        let speakers = try await store.fetchCallSpeakers(callID: callID)
        let profiles = try await store.fetchSpeakerProfiles()
        return TurnAttributor.fromStored(segments: segments, speakers: speakers, profiles: profiles)
    }
}

enum SampleCallFixture {
    static let priyaContactIdentifier = "callnotes-fixture-priya"

    static let referenceTurns = [
        DiarizationTurn(speaker: "A", start: 2.4, end: 5.0),
    ]

    static func embedding(_ values: [Float]) -> [Float] {
        values + Array(repeating: 0, count: max(EmbeddingModel.dimension - values.count, 0))
    }

    static func priyaEmbedding(cafURL: URL, diarizer: FluidDiarizer) async throws -> [Float] {
        let split = try ChannelAudio.splitStereoCAF(url: cafURL)
        let samples = split.far.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
        }
        return try await diarizer.enrollEmbedding(samples: samples)
    }

    static func materialize() throws -> (cafURL: URL, referenceTurns: [DiarizationTurn]) {
        let bundled =
            Bundle.main.url(forResource: "two-speaker", withExtension: "caf", subdirectory: "diarization")
            ?? Bundle.main.url(
                forResource: "two-speaker",
                withExtension: "caf",
                subdirectory: "Fixtures/diarization"
            )
            ?? Bundle.main.url(forResource: "two-speaker", withExtension: "caf")
        if let bundled {
            return (bundled, referenceTurns)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-two-speaker.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try ChannelAudio.writeStereoCAF(
                near: tone(frequency: 440, seconds: 3),
                far: Data(count: Int(2.4 * 16_000) * MemoryLayout<Int16>.size)
                    + tone(frequency: 660, seconds: 2.6),
                sampleRate: 16_000,
                to: url
            )
        }
        return (url, referenceTurns)
    }

    private static func tone(frequency: Double, seconds: Double, sampleRate: Double = 16_000) -> Data {
        let count = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = sin(2 * Double.pi * frequency * Double(index) / sampleRate)
            samples[index] = Int16((value * 0.2) * Double(Int16.max))
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}

private enum SampleCallError: LocalizedError {
    case emptyTranscription
    case missingPriyaProfile

    var errorDescription: String? {
        switch self {
        case .emptyTranscription:
            "Apple SpeechAnalyzer or FluidAudio returned no sample results."
        case .missingPriyaProfile:
            "The sample Priya profile is unavailable."
        }
    }
}
