import Foundation

/// How CallNotes treats recording consent on the Mac capture path
/// (plan section 13). Stored as `consent_policy` in UserDefaults.
public enum ConsentPolicy: String, Sendable, Codable, CaseIterable {
    /// The user will tell the other party. CallNotes does not inject audio.
    case announce
    /// Play a local recording notice and include its tone in the captured
    /// recording.
    case tone
    /// No notice. The user accepts one-party-consent risk.
    case off

    public static let defaultsKey = "consent_policy"
    public static let spokenLine = "This call is being recorded."

    public var injectsAnnouncement: Bool { self == .tone }

    public var displayName: String {
        switch self {
        case .announce: "Announce verbally"
        case .tone: "Play local announcement and tone"
        case .off: "Off"
        }
    }

    public var guidance: String {
        switch self {
        case .announce:
            "Tell the other party yourself. CallNotes does not inject audio into the call."
        case .tone:
            "CallNotes plays \"This call is being recorded\" plus a short tone through the Mac speakers and adds the tone to the saved recording. It cannot send this notice into FaceTime or Phone's microphone path."
        case .off:
            "No notice is given. You are responsible for consent where the law requires it."
        }
    }

    public static let farSideLimit =
        "The local announcement is not proof that the other party heard it. Announce verbally in all-party-consent regions."

    public static func resolved(_ raw: String?) -> ConsentPolicy {
        ConsentPolicy(rawValue: raw ?? "") ?? .announce
    }
}
