import Foundation

public enum CAFHeaderRepairError: Error, Equatable, Sendable {
    case notCAF
    case missingDataChunk
    case truncated
}

/// Makes an unclosed capture CAF readable. AVAudioFile and AudioFile only
/// finalize the `data` chunk size on a clean close, so a SIGKILL leaves a
/// header that still says the file is empty. The PCM bytes are already on
/// disk; this patches the size to match EOF.
public enum CAFHeaderRepair: Sendable {
    public static let magic = Data("caff".utf8)
    private static let dataFourCC = Data("data".utf8)
    private static let fileHeaderSize = 8
    private static let chunkHeaderSize = 12

    /// Returns true when the on-disk header was rewritten.
    @discardableResult
    public static func repairIfNeeded(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        var copy = data
        let changed = try patchDataChunkSize(&copy)
        if changed {
            try copy.write(to: url, options: .atomic)
        }
        try? CaptureChannelMarker.stampNearFar(url)
        return changed
    }

    /// True when the file looks like CAF capture audio that `StereoCAFReader`
    /// or `ChannelAudio.splitStereoCAF` can decode after repair.
    public static func isRepairableCAF(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > fileHeaderSize else {
            return false
        }
        return data.starts(with: magic)
    }

    static func patchDataChunkSize(_ data: inout Data) throws -> Bool {
        guard data.count >= fileHeaderSize, data.starts(with: magic) else {
            throw CAFHeaderRepairError.notCAF
        }
        var offset = fileHeaderSize
        while offset + chunkHeaderSize <= data.count {
            let type = data.subdata(in: offset..<(offset + 4))
            if type == dataFourCC {
                return try patchSize(in: &data, chunkOffset: offset)
            }
            let declaredSize = int64BE(data, at: offset + 4)
            // CAF uses -1 to mean "through EOF" while the file is still open.
            if declaredSize < 0 {
                break
            }
            let payload = Int(declaredSize)
            // Chunks pad to an even byte count; the pad is not in mChunkSize.
            // 8-byte alignment skips an `info` chunk of size 36 and misses `data`.
            let padded = payload + (payload & 1)
            let next = offset + chunkHeaderSize + padded
            if next <= offset { break }
            offset = next
        }
        if let found = data.range(of: dataFourCC, in: fileHeaderSize..<data.count) {
            return try patchSize(in: &data, chunkOffset: found.lowerBound)
        }
        throw CAFHeaderRepairError.missingDataChunk
    }

    private static func patchSize(in data: inout Data, chunkOffset offset: Int) throws -> Bool {
        let sizeOffset = offset + 4
        guard sizeOffset + 8 <= data.count else { throw CAFHeaderRepairError.truncated }
        let declaredSize = int64BE(data, at: sizeOffset)
        let payloadStart = offset + chunkHeaderSize
        guard payloadStart <= data.count else { throw CAFHeaderRepairError.truncated }
        let actualSize = Int64(data.count - payloadStart)
        if declaredSize == actualSize {
            return false
        }
        setInt64BE(&data, actualSize, at: sizeOffset)
        return true
    }

    private static func int64BE(_ data: Data, at offset: Int) -> Int64 {
        var value: Int64 = 0
        for i in 0..<8 {
            value = (value << 8) | Int64(data[offset + i])
        }
        return value
    }

    private static func setInt64BE(_ data: inout Data, _ value: Int64, at offset: Int) {
        var shift = 56
        for i in 0..<8 {
            data[offset + i] = UInt8(truncatingIfNeeded: value >> shift)
            shift -= 8
        }
    }
}
