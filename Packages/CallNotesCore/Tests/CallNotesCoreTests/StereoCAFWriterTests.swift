import Foundation
import Testing

@testable import CallNotesCore

@Suite struct StereoCAFWriterTests {
    @Test func writesNearOnLeftAndFarOnRight() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-caf-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let near: [Int16] = [100, 200, 300, 400]
        let far: [Int16] = [10, 20, 30, 40]
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        writer.close()
        #expect(writer.framesWritten == 4)

        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("caff".utf8)))

        let channels = try StereoCAFReader.read(url)
        #expect(channels.sampleRate == 16_000)
        #expect(channels.near == near)
        #expect(channels.far == far)
    }

    @Test func rejectsMismatchedChannelLengths() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-caf-mismatch-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StereoCAFWriter(url: url)
        #expect(throws: StereoCAFWriterError.channelLengthMismatch) {
            try writer.write(near: [1, 2], far: [1])
        }
    }
}