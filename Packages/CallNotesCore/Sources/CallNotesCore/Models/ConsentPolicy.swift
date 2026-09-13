import Foundation

/// How CallNotes treats recording consent on the Mac capture path
/// (plan section 13). Stored as `consent_policy` in UserDefaults.
public enum ConsentPolicy: String, Sendable, Codable, CaseIterable {
    /// The user will tell the other party. CallNotes does not inject audio.
    case announce
    /// Inject a short spoken line into the call's outbound path so the far
    /// side can hear it, not only the local speakers.
    case tone
    /// No notice. The user accepts one-party-consent risk.
    case off

    public static let defaultsKey = "consent_policy"
    public static let spokenLine = "This call is being recorded."

    public var injectsAnnouncement: Bool { self == .tone }

    public var displayName: String {
        switch self {
        case .announce: "Announce verbally"
        case .tone: "Play announcement on the call"
        case .off: "Off"
        }
    }

    public var guidance: String {
        switch self {
        case .announce:
            "Tell the other party yourself. CallNotes does not inject audio into the call."
        case .tone:
            "CallNotes plays \"This call is being recorded\" plus a short tone through the Mac speakers and mixes it into the microphone path so the other party can hear it on speakerphone."
        case .off:
            "No notice is given. You are responsible for consent where the law requires it."
        }
    }

    /// Headphones and a virtual-device-less Mac cannot put audio into FaceTime's
    /// input tap. The settings UI must say this; a live call is the only proof.
    public static let farSideLimit =
        "On speakerphone the other party can hear the announcement through the room. With headphones they may not. Announce verbally in all-party-consent regions until you have confirmed a live call."

    public static func resolved(_ raw: String?) -> ConsentPolicy {
        ConsentPolicy(rawValue: raw ?? "") ?? .announce
    }
}
