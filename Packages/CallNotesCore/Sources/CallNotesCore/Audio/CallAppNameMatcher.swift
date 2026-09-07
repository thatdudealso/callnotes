import Foundation

/// Display-name heuristic used to *observe* FaceTime / Phone bundle IDs at
/// first run. Bundle identifiers themselves are never hardcoded; once seen
/// they are stored by the Mac app and reused.
public enum CallAppNameMatcher: Sendable {
    public static func isCallAppDisplayName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.caseInsensitiveCompare("FaceTime") == .orderedSame
            || trimmed.caseInsensitiveCompare("Phone") == .orderedSame
    }

    /// Calendar / EventKit arm: a phone or FaceTime link in the event.
    public static func isCallLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("facetime")
            || lower.contains("tel:")
            || lower.contains("telprompt:")
            || lower.contains("telephony://")
    }
}