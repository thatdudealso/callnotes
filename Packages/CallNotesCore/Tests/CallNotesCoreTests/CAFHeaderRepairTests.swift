import Darwin
import Foundation
import Testing

@testable import CallNotesCore

@Suite struct CAFHeaderRepairTests {
    @Test func closedWriterStillReadsNearOnLeft() throws {
        let url = uniqueCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let near: [Int16] = [100, 200, 300, 400]
        let far: [Int16] = [10, 20, 30, 40]
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        writer.close()

        let channels = try StereoCAFReader.read(url)
        #expect(channels.near == near)
        #expect(channels.far == far)
        #expect(CaptureChannelMarker.hasNearFarMarker(url))
    }

    @Test func persistThenAbandonStillReadsAfterRepair() throws {
        let url = uniqueCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let near = (0..<1_600).map { Int16($0) }
        let far = (0..<1_600).map { Int16(-$0) }
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        writer.abandonWithoutClosing()

        let repaired = try CAFHeaderRepair.repairIfNeeded(url)
        _ = repaired
        let channels = try StereoCAFReader.read(url)
        #expect(channels.near == near)
        #expect(channels.far == far)
        let split = try ChannelAudio.splitStereoCAF(url: url)
        #expect(split.frameCount == 1_600)
    }

    @Test func zeroedDataChunkSizeIsRestored() throws {
        let url = uniqueCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let near: [Int16] = [1, 2, 3, 4, 5, 6, 7, 8]
        let far: [Int16] = [8, 7, 6, 5, 4, 3, 2, 1]
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        writer.close()

        var bytes = try Data(contentsOf: url)
        #expect(try CAFHeaderRepair.patchDataChunkSize(&bytes) == false)
        zeroDataChunkSize(&bytes)
        try bytes.write(to: url)

        #expect(try CAFHeaderRepair.repairIfNeeded(url))
        let channels = try StereoCAFReader.read(url)
        #expect(channels.near == near)
        #expect(channels.far == far)
    }

    @Test func processKillMidWriteLeavesProcessableCAF() throws {
        let url = uniqueCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 8_000
        let near = (0..<frames).map { Int16($0 % 1000) }
        let far = (0..<frames).map { Int16(-($0 % 1000)) }
        let writerURL = try #require(crashWriterExecutable())

        let process = Process()
        process.executableURL = writerURL
        process.arguments = [url.path, String(frames)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let ready = stdout.fileHandleForReading.readData(ofLength: 6)
        #expect(String(data: ready, encoding: .utf8) == "ready\n")
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(process.terminationStatus == SIGKILL || process.terminationReason == .uncaughtSignal)

        _ = try CAFHeaderRepair.repairIfNeeded(url)
        let channels = try StereoCAFReader.read(url)
        #expect(channels.near == near)
        #expect(channels.far == far)
        let split = try ChannelAudio.splitStereoCAF(url: url)
        #expect(split.frameCount == 8_000)
    }

    private func crashWriterExecutable() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let names = [
            ".build/debug/CAFCrashWriter",
            ".build/arm64-apple-macosx/debug/CAFCrashWriter",
            "debug/CAFCrashWriter",
            "arm64-apple-macosx/debug/CAFCrashWriter",
        ]
        for name in names {
            let url = cwd.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func uniqueCAF() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-caf-repair-\(UUID().uuidString).caf")
    }

    private func zeroDataChunkSize(_ data: inout Data) {
        var offset = 8
        let needle = Data("data".utf8)
        while offset + 12 <= data.count {
            let type = data.subdata(in: offset..<(offset + 4))
            if type == needle {
                for i in 0..<8 { data[offset + 4 + i] = 0 }
                return
            }
            var size: Int64 = 0
            for i in 0..<8 { size = (size << 8) | Int64(data[offset + 4 + i]) }
            if size < 0 { return }
            let payload = Int(size)
            let padded = payload + (payload & 1)
            offset += 12 + padded
        }
    }
}
