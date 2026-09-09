import Foundation

/// One PCM-frame range submitted as a file-import chunk.
public struct ImportFileChunk: Sendable, Equatable {
    public let startFrame: Int
    public let frameCount: Int

    public init(startFrame: Int, frameCount: Int) {
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}

/// Plans 9.5-minute chunks with a five-second overlap so speech that spans a
/// boundary is not dropped, then overlap-deduped after ASR.
///
/// Meta's file endpoint has a 10-minute / 32 MB cap; Apple and Parakeet reuse
/// the same plan so long imports stitch the same way on every engine.
public enum ImportFileChunker {
    public static let chunkDurationSeconds = 9.5 * 60
    public static let overlapDurationSeconds = 5.0

    public static func plan(totalFrames: Int, sampleRate: Int) -> [ImportFileChunk] {
        guard totalFrames > 0, sampleRate > 0 else { return [] }
        let chunkFrames = Int(chunkDurationSeconds * Double(sampleRate))
        let overlapFrames = Int(overlapDurationSeconds * Double(sampleRate))
        var result: [ImportFileChunk] = []
        var start = 0
        while start < totalFrames {
            let count = min(chunkFrames, totalFrames - start)
            result.append(ImportFileChunk(startFrame: start, frameCount: count))
            guard start + count < totalFrames else { break }
            start += max(1, count - overlapFrames)
        }
        return result
    }

    public static func pcmSlice(_ pcm: Data, chunk: ImportFileChunk) throws -> Data {
        let start = chunk.startFrame * 2
        let end = start + chunk.frameCount * 2
        guard start >= 0, end <= pcm.count, start < end else {
            throw FileImportError.invalidAudio("The requested import chunk is outside the source audio")
        }
        return pcm.subdata(in: start..<end)
    }
}

public enum ImportTranscriptOverlapDeduper {
    public static func merge(
        previous: [RawSegment],
        incoming: [RawSegment],
        incomingOffset: TimeInterval
    ) -> [RawSegment] {
        var merged = previous
        for segment in incoming {
            var translated = offset(segment, by: incomingOffset)
            let duplicateCount = merged.reduce(0) { count, existing in
                guard overlapsKnownWindow(translated, startingAt: incomingOffset),
                    overlaps(existing, translated), compatible(existing, translated)
                else {
                    return count
                }
                return max(count, sharedWordCount(existing.text, translated.text))
            }
            if duplicateCount < textWords(translated.text).count {
                if duplicateCount > 0 {
                    translated = trimLeadingWords(translated, count: duplicateCount)
                }
                merged.append(translated)
            }
        }
        return merged.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    private static func overlaps(_ lhs: RawSegment, _ rhs: RawSegment) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func overlapsKnownWindow(_ segment: RawSegment, startingAt start: TimeInterval) -> Bool {
        segment.start < start + ImportFileChunker.overlapDurationSeconds && start < segment.end
    }

    private static func compatible(_ lhs: RawSegment, _ rhs: RawSegment) -> Bool {
        (lhs.channel == nil || rhs.channel == nil || lhs.channel == rhs.channel)
            && (lhs.speakerTag == nil || rhs.speakerTag == nil || lhs.speakerTag == rhs.speakerTag)
    }

    private static func offset(_ segment: RawSegment, by offset: TimeInterval) -> RawSegment {
        var translated = segment
        translated.start += offset
        translated.end += offset
        translated.words = translated.words?.map { word in
            Word(text: word.text, start: word.start + offset, end: word.end + offset)
        }
        return translated
    }

    private static func trimLeadingWords(_ segment: RawSegment, count: Int) -> RawSegment {
        let words = textWords(segment.text)
        guard count > 0, count < words.count else { return segment }
        var trimmed = segment
        trimmed.text = words.dropFirst(count).map(\.original).joined(separator: " ")
        if let segmentWords = trimmed.words, segmentWords.count > count {
            trimmed.words = Array(segmentWords.dropFirst(count))
            trimmed.start = trimmed.words?.first?.start ?? trimmed.start
        } else {
            trimmed.start += (trimmed.end - trimmed.start) * Double(count) / Double(words.count)
        }
        return trimmed
    }

    private static func sharedWordCount(_ previous: String, _ incoming: String) -> Int {
        let trailing = textWords(previous).map(\.normalized)
        let leading = textWords(incoming).map(\.normalized)
        let maximum = min(trailing.count, leading.count)
        guard maximum > 0 else { return 0 }
        for count in stride(from: maximum, through: 1, by: -1) {
            if Array(trailing.suffix(count)) == Array(leading.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func textWords(_ text: String) -> [(original: String, normalized: String)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let normalized = token.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            guard !normalized.isEmpty else { return nil }
            return (String(token), normalized)
        }
    }
}

public enum FileImportError: Error, LocalizedError, Equatable {
    case unsupportedFile(String)
    case unsettled
    case duplicate
    case emptyTranscript
    case invalidAudio(String)
    case timeout
    case streamingUnsupported

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFile(name):
            "\(name) is not a supported import audio file"
        case .unsettled:
            "The inbox file is still being written"
        case .duplicate:
            "This recording was already imported"
        case .emptyTranscript:
            "No transcript segments were produced for the imported file"
        case let .invalidAudio(message):
            message
        case .timeout:
            "Timed out waiting for the inbox file to finish writing"
        case .streamingUnsupported:
            "This engine transcribes files in batch mode and does not start a live session"
        }
    }
}
