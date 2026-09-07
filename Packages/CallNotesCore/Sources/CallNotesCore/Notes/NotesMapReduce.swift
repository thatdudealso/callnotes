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
        let lines = transcript.labeledLines().flatMap(splitOversizedLine)
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

    private func splitOversizedLine(_ line: String) -> [String] {
        guard NotesContextBudget.estimateTokens(line) > chunkTokenBudget, chunkTokenBudget > 0 else {
            return [line]
        }
        guard let separator = line.range(of: ": ") else {
            return split(line, prefix: "")
        }
        let prefix = String(line[..<separator.upperBound])
        guard NotesContextBudget.estimateTokens(prefix) <= chunkTokenBudget else {
            return split(line, prefix: "")
        }
        return split(String(line[separator.upperBound...]), prefix: prefix)
    }

    private func split(_ text: String, prefix: String) -> [String] {
        let prefixBytes = prefix.utf8.count
        var chunks: [String] = []
        var chunk = prefix
        var chunkBytes = 0
        var hasContent = false
        for character in text {
            let characterBytes = String(character).utf8.count
            let candidateTokens = max((prefixBytes + chunkBytes + characterBytes) / 4, 1)
            if hasContent, candidateTokens > chunkTokenBudget {
                chunks.append(chunk)
                chunk = prefix
                chunkBytes = 0
                hasContent = false
            }
            chunk.append(character)
            chunkBytes += characterBytes
            hasContent = true
        }
        if hasContent {
            chunks.append(chunk)
        }
        return chunks
    }
}
