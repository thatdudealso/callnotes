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

    /// The phrase a person reads or hears for this state. Raw values are wire
    /// and column tokens, so no surface speaks them.
    public var displayName: String {
        switch self {
        case .notesReady: "Notes ready"
        case .transcribed: "Writing notes"
        case .failed: "Could not finish"
        case .recording, .uploaded, .transcribing: "Processing"
        }
    }
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
    public var sttProvider: STTProviderID {
        didSet {
            if !transcriptionProviders.contains(sttProvider) {
                transcriptionProviders.append(sttProvider)
            }
        }
    }
    public var transcriptionProviders: [STTProviderID]
    public var diarizationProvider: String?
    public var notesProvider: NotesProviderID?
    public var status: CallStatus
    public var consentAnnounced: Bool
    public var metaBilledSec: Int
    public var error: String?
    public var errorStage: String?

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
        transcriptionProviders: [STTProviderID] = [],
        diarizationProvider: String? = nil,
        notesProvider: NotesProviderID? = nil,
        status: CallStatus = .recording,
        consentAnnounced: Bool = false,
        metaBilledSec: Int = 0,
        error: String? = nil,
        errorStage: String? = nil
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
        self.transcriptionProviders = transcriptionProviders
        if !self.transcriptionProviders.contains(sttProvider) {
            self.transcriptionProviders.append(sttProvider)
        }
        self.diarizationProvider = diarizationProvider
        self.notesProvider = notesProvider
        self.status = status
        self.consentAnnounced = consentAnnounced
        self.metaBilledSec = metaBilledSec
        self.error = error
        self.errorStage = errorStage
    }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case startedAt
        case endedAt
        case durationSec
        case counterpartyName
        case counterpartyNumber
        case audioPath
        case audioChannels
        case sampleRate
        case sttProvider
        case transcriptionProviders
        case diarizationProvider
        case notesProvider
        case status
        case consentAnnounced
        case metaBilledSec
        case error
        case errorStage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            source: container.decode(CallSource.self, forKey: .source),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            endedAt: container.decodeIfPresent(Date.self, forKey: .endedAt),
            durationSec: container.decodeIfPresent(Int.self, forKey: .durationSec),
            counterpartyName: container.decodeIfPresent(String.self, forKey: .counterpartyName),
            counterpartyNumber: container.decodeIfPresent(String.self, forKey: .counterpartyNumber),
            audioPath: container.decode(String.self, forKey: .audioPath),
            audioChannels: container.decode(Int.self, forKey: .audioChannels),
            sampleRate: container.decode(Int.self, forKey: .sampleRate),
            sttProvider: container.decode(STTProviderID.self, forKey: .sttProvider),
            transcriptionProviders: container.decodeIfPresent([STTProviderID].self, forKey: .transcriptionProviders) ?? [],
            diarizationProvider: container.decodeIfPresent(String.self, forKey: .diarizationProvider),
            notesProvider: container.decodeIfPresent(NotesProviderID.self, forKey: .notesProvider),
            status: container.decode(CallStatus.self, forKey: .status),
            consentAnnounced: container.decode(Bool.self, forKey: .consentAnnounced),
            metaBilledSec: container.decode(Int.self, forKey: .metaBilledSec),
            error: container.decodeIfPresent(String.self, forKey: .error),
            errorStage: container.decodeIfPresent(String.self, forKey: .errorStage)
        )
    }
}
