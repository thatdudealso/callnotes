import AVFoundation
import Foundation

enum GenerateDiarizationFixture {
    static func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let out = root.appendingPathComponent("Fixtures/diarization/two-speaker.caf")
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let near = try synthesize(
            text: "Hello Priya, this is the near channel confirming the meeting time.",
            voices: ["Samantha", "Karen"]
        )
        let far = try synthesize(
            text: "Hi, this is Priya on the far channel. Let's ship the pilot next week.",
            voices: ["Daniel", "Karen"]
        )
        try writeStereoCAF(near: near, far: far, sampleRate: 16_000, to: out)
        FileHandle.standardError.write(
            Data("wrote \(out.path)\n".utf8)
        )
    }

    static func synthesize(text: String, voices: [String]) throws -> Data {
        var lastStatus = 1
        for voice in voices {
            do {
                return try synthesize(text: text, voice: voice)
            } catch {
                lastStatus = (error as NSError).code
            }
        }
        throw NSError(domain: "GenerateDiarizationFixture", code: lastStatus)
    }

    static func synthesize(text: String, voice: String) throws -> Data {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-\(voice)-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice, "-r", "160",
            "-o", aiff.path,
            text,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenerateDiarizationFixture",
                code: Int(process.terminationStatus)
            )
        }
        let file = try AVAudioFile(forReading: aiff)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        buffer.frameLength = frames
        var samples = [Int16](repeating: 0, count: Int(frames))
        if file.processingFormat.commonFormat == .pcmFormatInt16,
            let src = buffer.int16ChannelData
        {
            memcpy(&samples, src[0], Int(frames) * MemoryLayout<Int16>.size)
        } else if let src = buffer.floatChannelData {
            for index in 0..<Int(frames) {
                samples[index] = Int16(max(-1, min(1, src[0][index])) * Float(Int16.max))
            }
        }
        try? FileManager.default.removeItem(at: aiff)
        return samples.withUnsafeBytes { Data($0) }
    }

    static func writeStereoCAF(near: Data, far: Data, sampleRate: Double, to url: URL) throws {
        let frames = max(near.count / 2, far.count / 2)
        // Fill a planar Float32 buffer; AVAudioFile coerces CAF to interleaved.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(frames, 1))
        )!
        buffer.frameLength = AVAudioFrameCount(frames)
        let dest = buffer.floatChannelData!
        near.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                dest[0][index] = index < src.count ? Float(src[index]) / Float(Int16.max) : 0
            }
        }
        far.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                dest[1][index] = index < src.count ? Float(src[index]) / Float(Int16.max) : 0
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

do {
    try await GenerateDiarizationFixture.run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
