import Foundation

/// Immutable Ollama notes-model references. Digests match `docs/models.md`.
public struct PinnedNotesModel: Sendable, Equatable {
    public var name: String
    public var digest: String
    public var providerID: NotesProviderID

    public init(name: String, digest: String, providerID: NotesProviderID) {
        self.name = name
        self.digest = digest
        self.providerID = providerID
    }

    public static let glimmer = PinnedNotesModel(
        name: "muse-glimmer:30b",
        digest: "sha256:de878ce33ad81d060001db1469a02eebe4d86f0ad58cfe52dc062fdcbe4464c1",
        providerID: .glimmer
    )

    public static let fallbackInstruct = PinnedNotesModel(
        name: "qwen3:30b-instruct",
        digest: "sha256:19e422b0231392335cfc49cfd172de7034bb1aeabb08aa307cce745c60b272fe",
        providerID: .fallbackInstruct
    )

    public static let all: [PinnedNotesModel] = [.glimmer, .fallbackInstruct]

    public func matches(digest other: String) -> Bool {
        let expected = digest.lowercased()
        let actual = other.lowercased()
        return actual == expected
            || actual == expected.replacingOccurrences(of: "sha256:", with: "")
            || expected.hasSuffix(actual)
    }
}

/// Context window used for deep notes (plan section 7.3).
public enum NotesContextBudget: Sendable {
    public static let numCtx = 32_768
    public static let promptReserveTokens = 4_096
    public static let maxTranscriptTokens = numCtx - promptReserveTokens
    public static let chunkTokens = 8_192
    public static let speedTarget = Duration.seconds(60)

    public static func estimateTokens(_ text: String) -> Int {
        max(text.utf8.count / 4, text.isEmpty ? 0 : 1)
    }
}
