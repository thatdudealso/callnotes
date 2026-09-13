import Foundation

/// Age-based deletion of recordings and, optionally, derived rows
/// (plan section 8.2). Default is keep forever.
public struct RetentionPolicy: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Never delete audio or derived data.
        case keepForever = "keep_forever"
        /// Delete audio files after `days`, keep transcript and notes.
        case deleteAudioKeepTranscript = "delete_audio"
        /// Delete audio, the call row, segments, and notes after `days`.
        case deleteAll = "delete_all"
    }

    public static let modeDefaultsKey = "retention_mode"
    public static let daysDefaultsKey = "retention_days"
    public static let keepForeverSentinel = 0

    public var mode: Mode
    public var days: Int

    public init(mode: Mode = .keepForever, days: Int = keepForeverSentinel) {
        self.mode = mode
        self.days = max(0, days)
        if self.days == Self.keepForeverSentinel {
            self.mode = .keepForever
        }
    }

    public var deletesAudio: Bool {
        mode == .deleteAudioKeepTranscript || mode == .deleteAll
    }

    public var deletesDerivedData: Bool { mode == .deleteAll }

    public var isActive: Bool { mode != .keepForever && days > 0 }

    public func cutoff(now: Date) -> Date? {
        guard isActive else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    public static func resolved(mode: String?, days: Int?) -> RetentionPolicy {
        let parsedDays = max(0, days ?? keepForeverSentinel)
        if parsedDays == keepForeverSentinel {
            return RetentionPolicy(mode: .keepForever, days: keepForeverSentinel)
        }
        let parsedMode = Mode(rawValue: mode ?? "") ?? .deleteAudioKeepTranscript
        return RetentionPolicy(mode: parsedMode, days: parsedDays)
    }
}
