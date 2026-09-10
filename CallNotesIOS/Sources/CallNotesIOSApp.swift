import AVFoundation
import CallNotesCore
import Observation
import SwiftData
import SwiftUI

@main
struct CallNotesIOSApp: App {
    private let container: ModelContainer

    init() {
        container = try! ModelContainer(for: MirroredCall.self, MirroredSegment.self, MirroredNote.self)
    }

    var body: some Scene {
        WindowGroup { RootTabView() }
            .modelContainer(container)
    }
}

struct RootTabView: View {
    @State private var model = PhoneAppModel()

    var body: some View {
        TabView {
            Tab("Calls", systemImage: "list.bullet.rectangle") { CallsView(model: model) }
            Tab("Record", systemImage: "record.circle") { RecordView(model: model) }
            Tab("Settings", systemImage: "gearshape") { PhoneSettingsView(model: model) }
        }
        .task { await model.resumePendingUploads() }
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

@Observable @MainActor
final class PhoneAppModel {
    var isPaired = false
    var pairedMacName = "Your Mac"
    var uploadStatus: String?
    var recorder = InPersonRecorder()

    func resumePendingUploads() async { uploadStatus = await BackgroundUploadCoordinator.shared.resume() }
    func startRecording() async {
        do { try await recorder.start() } catch { uploadStatus = error.localizedDescription }
    }
    func stopRecording() async {
        do {
            let audioURL = try recorder.stop()
            let inbox = try PhoneSharedContainer.inbox()
            _ = try await inbox.enqueue(audioAt: audioURL, metadata: .init(source: .iphoneMeeting, startedAt: Date()))
            uploadStatus = await BackgroundUploadCoordinator.shared.resume()
        } catch { uploadStatus = error.localizedDescription }
    }
}

struct CallsView: View {
    @Bindable var model: PhoneAppModel
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
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await model.resumePendingUploads() } }
                    .accessibilityLabel("Sync calls with Mac")
            }
        }
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
                    TextField("Pairing code", text: $pairingCode).textInputAutocapitalization(.never)
                    Button("Pair") { model.isPaired = !pairingCode.isEmpty }.disabled(pairingCode.isEmpty)
                }
                Section("Processing") {
                    Toggle("Use on-device fallback", isOn: .constant(false)).disabled(true)
                    Text("Your recordings upload to your paired Mac for processing.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Retention") { LabeledContent("Shared recording files", value: "Until uploaded") }
                if let status = model.uploadStatus { Section("Uploads") { Text(status).foregroundStyle(.secondary) } }
            }.navigationTitle("Settings")
            .sheet(isPresented: $showingScanner) { QRScannerSheet { pairingCode = $0 } }
        }
    }
}

@MainActor final class InPersonRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let url = try PhoneSharedContainer.recordingsDirectory().appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        recorder?.record(); isRecording = true
    }
    func stop() throws -> URL {
        guard let recorder else { throw CocoaError(.fileNoSuchFile) }
        recorder.stop(); isRecording = false; self.recorder = nil; return recorder.url
    }
}
