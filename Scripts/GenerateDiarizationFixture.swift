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

        let near = trim(
            try synthesize(
                text: "Hello Priya, this is the near channel confirming the meeting time.",
                voices: ["Samantha", "Karen"]
            ),
            to: 3.0
        )
        let farSpeech = trim(
            try synthesize(
                text: "Hi, this is Priya on the far channel. Let's ship the pilot next week.",
                voices: ["Daniel", "Karen"]
            ),
            to: 2.6
        )
        let farDelay = Data(count: Int(2.4 * 16_000) * MemoryLayout<Int16>.size)
        try writeStereoCAF(near: near, far: farDelay + farSpeech, sampleRate: 16_000, to: out)
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
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: sourceBuffer)
        sourceBuffer.frameLength = frames
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let ratio = 16_000 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(max((Double(frames) * ratio).rounded(.up), 1))
        let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)!
        let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)!
        converter.primeMethod = .none
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return sourceBuffer
        }
        try? FileManager.default.removeItem(at: aiff)
        let outFrames = Int(converted.frameLength)
        guard outFrames > 0, let channel = converted.int16ChannelData?[0] else {
            throw NSError(domain: "GenerateDiarizationFixture", code: 2)
        }
        return Data(bytes: channel, count: outFrames * MemoryLayout<Int16>.size)
    }

    static func trim(_ pcm16: Data, to duration: Double, sampleRate: Double = 16_000) -> Data {
        let byteCount = Int(duration * sampleRate) * MemoryLayout<Int16>.size
        return Data(pcm16.prefix(byteCount))
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
