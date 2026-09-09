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

/// Removes only text duplicated by the known upload overlap. Requires both
/// temporal overlap and normalized-text equality so repeated conversational
/// phrases outside the overlap remain intact.
public enum ImportTranscriptOverlapDeduper {
    public static func merge(
        previous: [RawSegment],
        incoming: [RawSegment],
        incomingOffset: TimeInterval
    ) -> [RawSegment] {
        var merged = previous
        for var segment in incoming {
            segment.start += incomingOffset
            segment.end += incomingOffset
            let duplicate = merged.contains { existing in
                overlaps(existing, segment) && normalized(existing.text) == normalized(segment.text)
            }
            if !duplicate { merged.append(segment) }
        }
        return merged.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    private static func overlaps(_ lhs: RawSegment, _ rhs: RawSegment) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
