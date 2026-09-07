import Foundation

/// Splits a long transcript into segment windows when one-shot context would truncate.
public struct NotesMapReduce: Sendable {
    public var transcriptTokenBudget: Int
    public var chunkTokenBudget: Int
    public var reducePromptTokenBudget: Int

    public init(
        transcriptTokenBudget: Int = NotesContextBudget.maxTranscriptTokens,
        chunkTokenBudget: Int = NotesContextBudget.chunkTokens,
        reducePromptTokenBudget: Int = NotesContextBudget.maxTranscriptTokens
    ) {
        self.transcriptTokenBudget = transcriptTokenBudget
        self.chunkTokenBudget = chunkTokenBudget
        self.reducePromptTokenBudget = reducePromptTokenBudget
    }

    public static let `default` = NotesMapReduce()

    public func needsChunking(_ dialogue: String) -> Bool {
        NotesContextBudget.estimateTokens(dialogue) > transcriptTokenBudget
    }

    /// Groups consecutive segments so each window stays under `chunkTokenBudget`.
    public func windows(from transcript: Transcript) -> [String] {
        let lines = transcript.labeledLines()
        guard !lines.isEmpty else { return [] }

        var windows: [String] = []
        var current: [String] = []
        var tokens = 0
        for line in lines {
            let lineTokens = NotesContextBudget.estimateTokens(line)
            if !current.isEmpty, tokens + lineTokens > chunkTokenBudget {
                windows.append(current.joined(separator: "\n"))
                current = [line]
                tokens = lineTokens
            } else {
                current.append(line)
                tokens += lineTokens
            }
        }
        if !current.isEmpty {
            windows.append(current.joined(separator: "\n"))
        }
        return windows
    }
}
