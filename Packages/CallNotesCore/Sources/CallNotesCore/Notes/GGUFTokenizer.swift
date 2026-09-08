import Foundation

/// Tokenizes a rendered prompt from the vocabulary embedded in an Ollama GGUF.
/// This is used only by older Ollama versions that do not expose `/api/tokenize`.
struct GGUFTokenizer {
    private let tokens: Set<String>
    private let mergeRanks: [String: Int]
    private let addBOS: Bool

    init(modelFile: URL) throws {
        var reader = try GGUFReader(url: modelFile)
        let metadata = try reader.tokenizerMetadata()
        tokens = Set(metadata.tokens)
        mergeRanks = Dictionary(
            uniqueKeysWithValues: metadata.merges.enumerated().compactMap { index, merge in
                let pair = merge.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard pair.count == 2 else { return nil }
                return ("\(pair[0])\u{0}\(pair[1])", index)
            }
        )
        addBOS = metadata.addBOS
    }

    func tokenCount(_ prompt: String) -> Int {
        let specialTokens = tokens.filter { $0.hasPrefix("<|") && $0.hasSuffix("|>") }
        let pieces = split(prompt, on: specialTokens)
        let count = pieces.reduce(into: 0) { total, piece in
            if specialTokens.contains(piece) {
                total += 1
            } else {
                total += tokenizeText(piece)
            }
        }
        return count + (addBOS ? 1 : 0)
    }

    private func tokenizeText(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let expression = try! NSRegularExpression(
            pattern: "(?i)'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
        )
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).reduce(0) { count, match in
            guard let matchRange = Range(match.range, in: text) else { return count }
            return count + bpeTokenCount(String(text[matchRange]))
        }
    }

    private func bpeTokenCount(_ text: String) -> Int {
        var symbols = text.utf8.map { Self.byteToUnicode[$0]! }
        while symbols.count > 1 {
            var best: (index: Int, rank: Int)?
            for index in symbols.indices.dropLast() {
                guard let rank = mergeRanks["\(symbols[index])\u{0}\(symbols[index + 1])"] else { continue }
                if best == nil || rank < best!.rank {
                    best = (index, rank)
                }
            }
            guard let best else { break }
            symbols[best.index] += symbols[best.index + 1]
            symbols.remove(at: best.index + 1)
        }
        return symbols.count
    }

    private func split(_ prompt: String, on specialTokens: Set<String>) -> [String] {
        guard !specialTokens.isEmpty else { return [prompt] }
        let expression = try! NSRegularExpression(
            pattern: specialTokens.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        )
        let range = NSRange(prompt.startIndex..., in: prompt)
        var pieces: [String] = []
        var position = prompt.startIndex
        for match in expression.matches(in: prompt, range: range) {
            guard let matchRange = Range(match.range, in: prompt) else { continue }
            if position < matchRange.lowerBound { pieces.append(String(prompt[position..<matchRange.lowerBound])) }
            pieces.append(String(prompt[matchRange]))
            position = matchRange.upperBound
        }
        if position < prompt.endIndex { pieces.append(String(prompt[position...])) }
        return pieces
    }

    private static let byteToUnicode: [UInt8: String] = {
        var values = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = values
        for byte in 0...255 where !values.contains(byte) {
            values.append(byte)
            scalars.append(256 + scalars.count - (Array(33...126) + Array(161...172) + Array(174...255)).count)
        }
        return Dictionary(uniqueKeysWithValues: zip(values, scalars).map {
            (UInt8($0.0), String(UnicodeScalar($0.1)!))
        })
    }()
}

private struct GGUFTokenizerMetadata {
    var tokens: [String]
    var merges: [String]
    var addBOS: Bool
}

private struct GGUFReader {
    private var handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    mutating func tokenizerMetadata() throws -> GGUFTokenizerMetadata {
        guard try readString(count: 4) == "GGUF" else {
            throw NotesGenerationError.ollamaUnavailable("Ollama model is not a GGUF file")
        }
        _ = try readUInt32()
        _ = try readUInt64()
        let metadataCount = try readUInt64()
        var tokens: [String] = []
        var merges: [String] = []
        var addBOS = false
        for _ in 0..<metadataCount {
            let key = try readString()
            let type = try readUInt32()
            switch key {
            case "tokenizer.ggml.tokens": tokens = try readStringArray(type: type)
            case "tokenizer.ggml.merges": merges = try readStringArray(type: type)
            case "tokenizer.ggml.add_bos_token": addBOS = try readBool(type: type)
            default: try skip(type: type)
            }
        }
        guard !tokens.isEmpty, !merges.isEmpty else {
            throw NotesGenerationError.ollamaUnavailable("GGUF model has no BPE tokenizer metadata")
        }
        return GGUFTokenizerMetadata(tokens: tokens, merges: merges, addBOS: addBOS)
    }

    private mutating func readStringArray(type: UInt32) throws -> [String] {
        guard type == 9, try readUInt32() == 8 else { throw NotesGenerationError.ollamaUnavailable("Unsupported GGUF tokenizer array") }
        return try (0..<readUInt64()).map { _ in try readString() }
    }

    private mutating func readBool(type: UInt32) throws -> Bool {
        guard type == 7 else { throw NotesGenerationError.ollamaUnavailable("Unsupported GGUF boolean") }
        return try readByte() != 0
    }

    private mutating func skip(type: UInt32) throws {
        switch type {
        case 0, 1, 7: try skip(1)
        case 2, 3: try skip(2)
        case 4, 5, 6: try skip(4)
        case 10, 11, 12: try skip(8)
        case 8: try skip(Int(try readUInt64()))
        case 9:
            let elementType = try readUInt32()
            let count = try readUInt64()
            if elementType == 8 {
                for _ in 0..<count { try skip(Int(try readUInt64())) }
            } else {
                let sizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
                guard let size = sizes[elementType] else { throw NotesGenerationError.ollamaUnavailable("Unsupported GGUF metadata") }
                try skip(size * Int(count))
            }
        default: throw NotesGenerationError.ollamaUnavailable("Unsupported GGUF metadata")
        }
    }

    private mutating func readString(count: Int? = nil) throws -> String {
        let length: Int
        if let count {
            length = count
        } else {
            length = Int(try readUInt64())
        }
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length, let value = String(data: data, encoding: .utf8) else {
            throw NotesGenerationError.ollamaUnavailable("Invalid GGUF metadata")
        }
        return value
    }

    private mutating func readByte() throws -> UInt8 {
        try readData(1)[0]
    }

    private mutating func readUInt32() throws -> UInt32 {
        try readData(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private mutating func readUInt64() throws -> UInt64 {
        try readData(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    private mutating func readData(_ count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw NotesGenerationError.ollamaUnavailable("Truncated GGUF metadata") }
        return data
    }

    private mutating func skip(_ count: Int) throws {
        try handle.seek(toOffset: handle.offsetInFile + UInt64(count))
    }
}
