import Foundation

/// Where a call was captured.
public enum CallSource: String, Codable, Sendable, CaseIterable {
    case macFaceTime = "mac_facetime"
    case macPhone = "mac_phone"
    case macManual = "mac_manual"
    case iphoneRecording = "iphone_recording"
    case iphoneMeeting = "iphone_meeting"
    case iphoneSpeaker = "iphone_speaker"
    case fileImport = "import"
}

/// Pipeline state of a call, mirrored by the `calls.status` column.
public enum CallStatus: String, Codable, Sendable, CaseIterable {
    case recording
    case uploaded
    case transcribing
    case transcribed
    case notesReady = "notes_ready"
    case failed
}

/// A single captured call and its processing state.
public struct Call: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var source: CallSource
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSec: Int?
    public var counterpartyName: String?
    public var counterpartyNumber: String?
    public var audioPath: String
    public var audioChannels: Int
    public var sampleRate: Int
    public var sttProvider: STTProviderID
    public var status: CallStatus
    public var consentAnnounced: Bool
    public var metaBilledSec: Int

    public init(
        id: UUID = UUID(),
        source: CallSource,
        startedAt: Date,
        endedAt: Date? = nil,
        durationSec: Int? = nil,
        counterpartyName: String? = nil,
        counterpartyNumber: String? = nil,
        audioPath: String,
        audioChannels: Int = 2,
        sampleRate: Int = 16_000,
        sttProvider: STTProviderID,
        status: CallStatus = .recording,
        consentAnnounced: Bool = false,
        metaBilledSec: Int = 0
    ) {
        self.id = id
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.counterpartyName = counterpartyName
        self.counterpartyNumber = counterpartyNumber
        self.audioPath = audioPath
        self.audioChannels = audioChannels
        self.sampleRate = sampleRate
        self.sttProvider = sttProvider
        self.status = status
        self.consentAnnounced = consentAnnounced
        self.metaBilledSec = metaBilledSec
    }
}
