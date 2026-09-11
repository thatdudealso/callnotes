import AVFoundation
import CallNotesCore
import Observation
import SwiftData
import SwiftUI

/// The mirror is a cache of the Mac's history, so a store that cannot be opened
/// must never take the app down with it: the phone is the only process that can
/// drain the upload queue, and recordings already stopped and queued would be
/// stranded behind a launch crash.
@main
struct CallNotesIOSApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    private let container: ModelContainer?
    private let storeMessage: String?

    init() {
        do {
            container = try ModelContainer(for: MirroredCall.self, MirroredSegment.self, MirroredNote.self)
            storeMessage = nil
        } catch {
            let rebuilt = try? ModelContainer(
                for: MirroredCall.self, MirroredSegment.self, MirroredNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            container = rebuilt
            storeMessage = rebuilt == nil
                ? "Call history is unavailable on this iPhone. Queued recordings still upload to your Mac."
                : "Call history could not be opened, so it is being rebuilt from your Mac. Uploads are unaffected."
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                RootTabView(storeMessage: storeMessage).modelContainer(container)
            } else {
                MirrorUnavailableView(message: storeMessage)
            }
        }
    }
}

/// The mirror could not be opened even in memory, so `@Query` has no container
/// to read. Uploads still drain: that is the part the user cannot redo.
struct MirrorUnavailableView: View {
    let message: String?
    @State private var model = PhoneAppModel()

    var body: some View {
        ContentUnavailableView {
            Label("Call history unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message ?? "Call history is unavailable on this iPhone.")
        } actions: {
            if let status = model.uploadStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
        }
        .task { await model.resumePendingUploads() }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadCoordinator.shared.handleBackgroundEvents(for: identifier, completionHandler: completionHandler)
    }
}

struct RootTabView: View {
    @State private var model: PhoneAppModel
    @Environment(\.scenePhase) private var scenePhase

    init(storeMessage: String? = nil) {
        _model = State(initialValue: PhoneAppModel(storeMessage: storeMessage))
    }

    var body: some View {
        TabView {
            Tab("Calls", systemImage: "list.bullet.rectangle") { CallsView(model: model) }
            Tab("Record", systemImage: "record.circle") { RecordView(model: model) }
            Tab("Settings", systemImage: "gearshape") { PhoneSettingsView(model: model) }
        }
        .task { await model.resumePendingUploads() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshPairingState() }
        }
    }
}

@Model final class MirroredCall {
    @Attribute(.unique) var id: UUID
    var title: String
    var summary: String
    var startedAt: Date
    var source: String
    var status: String

    init(id: UUID, title: String, summary: String, startedAt: Date, source: String, status: String) {
        self.id = id; self.title = title; self.summary = summary
        self.startedAt = startedAt; self.source = source; self.status = status
    }
}

@Model final class MirroredSegment {
    @Attribute(.unique) var id: String
    var callID: UUID
    var speaker: String
    var text: String
    var startSec: Double

    init(id: String, callID: UUID, speaker: String, text: String, startSec: Double) {
        self.id = id; self.callID = callID; self.speaker = speaker; self.text = text; self.startSec = startSec
    }
}

@Model final class MirroredNote {
    @Attribute(.unique) var callID: UUID
    var summary: String
    var decisions: [String]
    var actionItems: [String]

    init(callID: UUID, summary: String, decisions: [String] = [], actionItems: [String] = []) {
        self.callID = callID; self.summary = summary; self.decisions = decisions; self.actionItems = actionItems
    }
}

/// SwiftData backing for `MirrorReconciler`. It only performs the writes the
/// reconciler asks for, so the cascade rules stay in one tested place.
///
/// The whole mirror is read once into identifier maps and every lookup is served
/// from them: `apply` runs on the main actor and touches every segment of every
/// call, so a fetch per row would hang the Calls tab for seconds on a normal
/// history.
final class SwiftDataMirrorWriter: MirrorWriting {
    private let context: ModelContext
    private var calls: [UUID: MirroredCall]
    private var segments: [String: MirroredSegment]
    private var segmentIDsByCall: [UUID: Set<String>]
    private var notes: [UUID: MirroredNote]

    init(context: ModelContext) throws {
        self.context = context
        calls = Dictionary(
            try context.fetch(FetchDescriptor<MirroredCall>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let storedSegments = try context.fetch(FetchDescriptor<MirroredSegment>())
        segments = Dictionary(storedSegments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        segmentIDsByCall = storedSegments.reduce(into: [:]) { index, segment in
            index[segment.callID, default: []].insert(segment.id)
        }
        notes = Dictionary(
            try context.fetch(FetchDescriptor<MirroredNote>()).map { ($0.callID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func localCallIDs() throws -> [UUID] {
        Array(calls.keys)
    }

    func localSegmentIDs(callID: UUID) throws -> [String] {
        Array(segmentIDsByCall[callID] ?? [])
    }

    func removeSegment(id: String) throws {
        guard let segment = segments.removeValue(forKey: id) else { return }
        segmentIDsByCall[segment.callID]?.remove(id)
        context.delete(segment)
    }

    func removeSegments(callID: UUID) throws {
        for id in segmentIDsByCall.removeValue(forKey: callID) ?? [] {
            if let segment = segments.removeValue(forKey: id) { context.delete(segment) }
        }
    }

    func removeNote(callID: UUID) throws {
        guard let note = notes.removeValue(forKey: callID) else { return }
        context.delete(note)
    }

    func removeCall(id: UUID) throws {
        guard let call = calls.removeValue(forKey: id) else { return }
        context.delete(call)
    }

    func upsertCall(_ remote: SyncDTO.MirroredCall) throws {
        guard let call = calls[remote.id] else {
            let call = MirroredCall(
                id: remote.id,
                title: remote.title,
                summary: remote.summary,
                startedAt: remote.startedAt,
                source: remote.source,
                status: remote.status
            )
            calls[remote.id] = call
            context.insert(call)
            return
        }
        if call.title != remote.title { call.title = remote.title }
        if call.summary != remote.summary { call.summary = remote.summary }
        if call.startedAt != remote.startedAt { call.startedAt = remote.startedAt }
        if call.source != remote.source { call.source = remote.source }
        if call.status != remote.status { call.status = remote.status }
    }

    func upsertSegment(_ remote: SyncDTO.MirroredSegment, callID: UUID) throws {
        guard let segment = segments[remote.id] else {
            let segment = MirroredSegment(
                id: remote.id,
                callID: callID,
                speaker: remote.speaker,
                text: remote.text,
                startSec: remote.startSec
            )
            segments[remote.id] = segment
            segmentIDsByCall[callID, default: []].insert(remote.id)
            context.insert(segment)
            return
        }
        if segment.callID != callID {
            segmentIDsByCall[segment.callID]?.remove(remote.id)
            segmentIDsByCall[callID, default: []].insert(remote.id)
            segment.callID = callID
        }
        if segment.speaker != remote.speaker { segment.speaker = remote.speaker }
        if segment.text != remote.text { segment.text = remote.text }
        if segment.startSec != remote.startSec { segment.startSec = remote.startSec }
    }

    func upsertNote(_ remote: SyncDTO.MirroredNote, callID: UUID) throws {
        guard let note = notes[callID] else {
            let note = MirroredNote(
                callID: callID,
                summary: remote.summary,
                decisions: remote.decisions,
                actionItems: remote.actionItems
            )
            notes[callID] = note
            context.insert(note)
            return
        }
        if note.summary != remote.summary { note.summary = remote.summary }
        if note.decisions != remote.decisions { note.decisions = remote.decisions }
        if note.actionItems != remote.actionItems { note.actionItems = remote.actionItems }
    }

    func commit() throws {
        guard context.hasChanges else { return }
        try context.save()
    }
}

@Observable @MainActor
final class PhoneAppModel {
    var isPaired = false
    var pairedMacName = "Your Mac"
    var uploadStatus: String?
    var storeMessage: String?
    var recorder = InPersonRecorder()
    @ObservationIgnored nonisolated(unsafe) private var pairingInvalidatedObserver: NSObjectProtocol?

    init(storeMessage: String? = nil) {
        self.storeMessage = storeMessage
        isPaired = PhonePairingStore.load() != nil
        pairingInvalidatedObserver = NotificationCenter.default.addObserver(
            forName: PhonePairingStore.pairingInvalidatedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showUnpairedState()
            }
        }
    }

    deinit {
        if let pairingInvalidatedObserver {
            NotificationCenter.default.removeObserver(pairingInvalidatedObserver)
        }
    }

    func resumePendingUploads() async { uploadStatus = await BackgroundUploadCoordinator.shared.resume() }
    func pair(ticketPayload: String) async {
        do {
            _ = try await PhonePairingCoordinator.pair(ticketPayload: ticketPayload, deviceName: UIDevice.current.name)
            isPaired = true
            pairedMacName = "Paired Mac"
            uploadStatus = await BackgroundUploadCoordinator.shared.resume()
        } catch {
            uploadStatus = error.localizedDescription
        }
    }
    func unpair() {
        PhonePairingStore.remove()
        showUnpairedState()
    }

    func refreshPairingState() {
        guard PhonePairingStore.load() != nil else {
            showUnpairedState()
            return
        }
        isPaired = true
        if pairedMacName == "Your Mac" { pairedMacName = "Paired Mac" }
    }

    private func showUnpairedState() {
        isPaired = false
        pairedMacName = "Your Mac"
        uploadStatus = PhoneSyncError.unpaired.localizedDescription
    }
    func refreshMirror(in context: ModelContext) async {
        do {
            let mirror = try await PhoneMirrorCoordinator.fetch()
            try MirrorReconciler.apply(mirror, to: SwiftDataMirrorWriter(context: context))
        } catch PhoneSyncError.unpaired {
            unpair()
        } catch { uploadStatus = error.localizedDescription }
    }
    func startRecording() async {
        do { try await recorder.start() } catch { uploadStatus = error.localizedDescription }
    }
    func stopRecording() async {
        defer { recorder.releaseRecordingFile() }
        do {
            let capture = try recorder.stop()
            try await BackgroundUploadCoordinator.shared.enqueue(
                audioAt: capture.url,
                metadata: .init(source: .iphoneMeeting, startedAt: capture.startedAt)
            )
            uploadStatus = await BackgroundUploadCoordinator.shared.resume()
        } catch { uploadStatus = error.localizedDescription }
    }
}

struct CallsView: View {
    @Bindable var model: PhoneAppModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MirroredCall.startedAt, order: .reverse) private var calls: [MirroredCall]

    var body: some View {
        NavigationStack {
            Group {
                if calls.isEmpty {
                    ContentUnavailableView("No calls yet", systemImage: "phone.badge.waveform", description: Text("Share a call recording from Notes, Voice Memos, Files, or Mail."))
                } else {
                    List(calls) { call in
                        NavigationLink(value: call.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(call.title).font(.headline)
                                Text(call.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                Text(call.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 4)
                        }.accessibilityLabel("\(call.title), \(call.status)")
                    }.navigationDestination(for: UUID.self) { CallDetailView(callID: $0) }
                }
            }
            .navigationTitle("Calls")
            .toolbar {
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await model.resumePendingUploads(); await model.refreshMirror(in: modelContext) } }
                    .accessibilityLabel("Sync calls with Mac")
            }
        }
        .task { await model.refreshMirror(in: modelContext) }
        .onAppear { model.refreshPairingState() }
    }
}

struct CallDetailView: View {
    let callID: UUID
    @Query private var calls: [MirroredCall]
    @Query private var notes: [MirroredNote]
    @Query private var segments: [MirroredSegment]

    init(callID: UUID) {
        self.callID = callID
        _calls = Query(filter: #Predicate { $0.id == callID })
        _notes = Query(filter: #Predicate { $0.callID == callID })
        _segments = Query(filter: #Predicate { $0.callID == callID }, sort: \MirroredSegment.startSec)
    }

    var body: some View {
        List {
            if let call = calls.first {
                Section("Notes") {
                    Text(notes.first?.summary ?? call.summary)
                    ForEach(notes.first?.decisions ?? [], id: \.self) { Text($0) }
                    ForEach(notes.first?.actionItems ?? [], id: \.self) { Label($0, systemImage: "checkmark.circle") }
                }
            }
            Section("Transcript") {
                ForEach(segments) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(segment.speaker).font(.caption.weight(.semibold)).foregroundStyle(Color.blue)
                        Text(segment.text)
                    }
                    .accessibilityLabel("\(segment.speaker): \(segment.text)").padding(.vertical, 3)
                }
            }
        }
        .navigationTitle(calls.first?.title ?? "Call").navigationBarTitleDisplayMode(.inline)
    }
}

struct RecordView: View {
    @Bindable var model: PhoneAppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Button {
                        Task { if model.recorder.isRecording { await model.stopRecording() } else { await model.startRecording() } }
                    } label: {
                        Image(systemName: model.recorder.isRecording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 76)).foregroundStyle(model.recorder.isRecording ? Color.red : Color.blue)
                            .frame(width: 144, height: 144).background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel(model.recorder.isRecording ? "Stop recording" : "Start in-person recording")
                    .accessibilityHint("Audio uploads to your paired Mac when you stop.")
                    Text(model.recorder.isRecording ? "Recording" : "In-person meeting").font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 12) {
                        Label("How to record a phone call", systemImage: "phone.arrow.up.right").font(.headline)
                        Text("1. Start Apple’s built-in call recording.\n2. Open the recording in Notes.\n3. Share it to CallNotes.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.padding()
            }.navigationTitle("Record")
        }
    }
}

struct PhoneSettingsView: View {
    @Bindable var model: PhoneAppModel
    @State private var pairingCode = ""
    @State private var showingScanner = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    LabeledContent("Status", value: model.isPaired ? "Connected" : "Not paired")
                    if model.isPaired { LabeledContent("Mac", value: model.pairedMacName) }
                    Button(model.isPaired ? "Pair another Mac" : "Scan pairing QR code") { showingScanner = true }
                        .accessibilityLabel("Scan Mac pairing QR code")
                    TextField("Pairing QR payload", text: $pairingCode).textInputAutocapitalization(.never)
                    Button("Pair") { Task { await model.pair(ticketPayload: pairingCode) } }.disabled(pairingCode.isEmpty)
                    if model.isPaired {
                        Button("Forget this Mac", role: .destructive) { model.unpair() }
                    }
                }
                Section("Processing") {
                    Toggle("Use on-device fallback", isOn: .constant(false)).disabled(true)
                    Text("Your recordings upload to your paired Mac for processing.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Retention") { LabeledContent("Shared recording files", value: "Until uploaded") }
                if let status = model.uploadStatus { Section("Uploads") { Text(status).foregroundStyle(.secondary) } }
                if let storeMessage = model.storeMessage {
                    Section("Call history") {
                        Label(storeMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Settings")
            .onAppear { model.refreshPairingState() }
            .sheet(isPresented: $showingScanner) { QRScannerSheet { code in
                pairingCode = code
                Task { await model.pair(ticketPayload: code) }
            } }
        }
    }
}

/// `@Observable`, not `ObservableObject`: `PhoneAppModel` is `@Observable`, so a
/// `@Published` flag on a nested legacy object would never invalidate the view
/// that reads it and the Record button would not flip while audio is capturing.
@Observable @MainActor final class InPersonRecorder {
    private(set) var isRecording = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var lease: SharedAudioStaging.Lease?
    @ObservationIgnored private var captureStartedAt: Date?
    @ObservationIgnored private var isStarting = false

    /// The Record button reads `isRecording`, which only flips once capture is
    /// running, so a second tap during permission and session setup would start
    /// a second recorder on the same route and strand the first one's lease.
    func start() async throws {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "CallNotes.Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "CallNotes needs microphone access to record."])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        var recordingStarted = false
        var stagingLease: SharedAudioStaging.Lease?
        defer {
            if !recordingStarted {
                stagingLease?.release()
                Self.deactivateSession()
            }
        }
        let url = try PhoneSharedContainer.recordingsDirectory().appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let lease = try SharedAudioStaging.Lease(audioURL: url)
        stagingLease = lease
        recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        guard recorder?.record() == true else {
            recorder = nil
            throw NSError(domain: "CallNotes.Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start recording."])
        }
        self.lease = lease
        captureStartedAt = Date()
        isRecording = true
        recordingStarted = true
    }

    /// The capture start, not the moment Stop was tapped: history ordering and
    /// dashboard periods key off this, so a 45-minute meeting must not land
    /// 45 minutes late.
    func stop() throws -> (url: URL, startedAt: Date) {
        defer { Self.deactivateSession() }
        guard let recorder, let captureStartedAt else {
            isRecording = false
            throw CocoaError(.fileNoSuchFile)
        }
        recorder.stop()
        isRecording = false
        self.recorder = nil
        self.captureStartedAt = nil
        return (recorder.url, captureStartedAt)
    }

    /// `.record` does not mix, so holding the session after Stop keeps the route,
    /// the microphone indicator, and the background-audio assertion, and whatever
    /// the user was playing never resumes.
    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Held from `start` until the upload queue owns the bytes, so the launch
    /// sweep never collects a recording that is still being captured or handed
    /// over, and a force-quit mid-recording leaves one the sweep can collect.
    func releaseRecordingFile() {
        lease?.release()
        lease = nil
    }
}
