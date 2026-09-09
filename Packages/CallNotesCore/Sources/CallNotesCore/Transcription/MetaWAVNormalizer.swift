@preconcurrency import AVFoundation
import Foundation

/// Converts captured CAF/m4a input into the narrowly supported WAV format the
/// Meta file endpoint accepts. Already-valid WAV is passed through untouched.
public enum MetaWAVNormalizer {
    public static func normalizedWAV(
        from inputURL: URL,
        maximumOutputBytes: Int = .max
    ) throws -> (url: URL, isTemporary: Bool) {
        let inputBytes = (try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if inputBytes <= maximumOutputBytes, (try? MetaWAV.read(fileURL: inputURL)) != nil {
            return (inputURL, false)
        }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: inputURL)
        } catch {
            throw MetaTranscriptionError.invalidWAV("CallNotes could not decode this audio file")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MetaAudioFormat.pcm24KHz.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: input.processingFormat, to: targetFormat)
        else {
            throw MetaTranscriptionError.invalidWAV("CallNotes could not convert this audio file to Meta's WAV format")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-meta-\(UUID().uuidString).wav")
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: outputURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw MetaTranscriptionError.invalidWAV("CallNotes could not create a Meta-compatible WAV file")
        }
        let sourceCapacity: AVAudioFrameCount = 8_192
        while true {
            guard let source = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat,
                frameCapacity: sourceCapacity
            ) else {
                throw MetaTranscriptionError.invalidWAV("CallNotes could not allocate an audio conversion buffer")
            }
            try input.read(into: source, frameCount: sourceCapacity)
            guard source.frameLength > 0 else { break }
            let ratio = targetFormat.sampleRate / input.processingFormat.sampleRate
            let outputCapacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw MetaTranscriptionError.invalidWAV("CallNotes could not allocate a WAV output buffer")
            }
            let inputState = ConversionInput(source)
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { [inputState] _, outStatus in
                if inputState.consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputState.consumed = true
                outStatus.pointee = .haveData
                return inputState.source
            }
            if status == .error {
                throw MetaTranscriptionError.invalidWAV(
                    conversionError?.localizedDescription ?? "CallNotes could not convert this audio file"
                )
            }
            if converted.frameLength > 0 {
                let projectedBytes = Int(output.framePosition + Int64(converted.frameLength)) * 2 + 44
                guard projectedBytes <= maximumOutputBytes else {
                    throw MetaTranscriptionError.invalidWAV("The normalized audio exceeds Meta's import limit")
                }
                try output.write(from: converted)
            }
        }
        completed = true
        return (outputURL, true)
    }
}

/// AVAudioConverter invokes its input closure synchronously for this single
/// conversion. The wrapper limits the unchecked boundary to that API contract.
private final class ConversionInput: @unchecked Sendable {
    let source: AVAudioPCMBuffer
    var consumed = false

    init(_ source: AVAudioPCMBuffer) {
        self.source = source
    }
}
