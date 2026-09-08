import Foundation

/// Multipart client for the Meta file-transcription endpoint. Input is always
/// normalized WAV because the endpoint rejects CAF, m4a, stereo, float, and
/// unsupported sample rates.
public struct MetaFileProvider: STTProvider {
    public let id: STTProviderID = .metaMuse
    public let supportsStreaming = false
    public let providesDiarization = true
    public let sendsAudioOffDevice = true

    public let configuration: MetaTranscriptionConfiguration
    public let endpoint: URL

    public init(
        configuration: MetaTranscriptionConfiguration,
        endpoint: URL = URL(string: "https://api.meta.ai/v1/asr/transcribe")!
    ) {
        self.configuration = configuration
        self.endpoint = endpoint
    }

    public func healthCheck() async -> ProviderHealth {
        configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .unavailable(reason: "A Meta Model API key has not been configured")
            : .healthy
    }

    public func startSession(config: STTSessionConfig) async throws -> STTSession {
        throw MetaTranscriptionError.unexpectedResponse("Meta file transcription does not support live sessions")
    }

    public func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment] {
        try await transcribeWithReceipt(fileURL: fileURL, config: config).segments
    }

    /// Use this variant where the caller persists `calls.meta_billed_sec`.
    /// Meta charges audio actually processed, rounded down per response.
    public func transcribeWithReceipt(
        fileURL: URL,
        config: STTSessionConfig
    ) async throws -> MetaFileTranscriptionResult {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MetaTranscriptionError.missingAPIKey
        }
        try MetaFileLimits.validate(
            try fileSize(of: fileURL),
            maximum: MetaFileLimits.maximumInputBytes,
            message: "The selected audio file exceeds Meta's import limit"
        )
        let normalized = try MetaWAVNormalizer.normalizedWAV(from: fileURL)
        defer {
            if normalized.isTemporary {
                try? FileManager.default.removeItem(at: normalized.url)
            }
        }
        try MetaFileLimits.validate(
            try fileSize(of: normalized.url),
            maximum: MetaFileLimits.maximumNormalizedBytes,
            message: "The normalized audio exceeds Meta's import limit"
        )
        let wav = try MetaWAV.read(fileURL: normalized.url)
        let plans = MetaFileChunker.plan(totalFrames: wav.frameCount, sampleRate: wav.sampleRate)
        var segments: [RawSegment] = []
        var billedSeconds = 0

        for chunk in plans {
            let chunkWAV = try wav.data(for: chunk)
            try MetaFileLimits.validate(
                chunkWAV.count,
                maximum: MetaFileLimits.maximumChunkBytes,
                message: "A Meta upload chunk exceeds the request limit"
            )
            let response = try await upload(wavData: chunkWAV, config: config)
            billedSeconds += MetaCostMeter.billedSeconds(audioProcessedMilliseconds: response.audioDurationMs)
            let offset = Double(chunk.startFrame) / Double(wav.sampleRate)
            let translated = response.rawSegments(offset: offset)
            segments = MetaTranscriptOverlapDeduper.merge(
                previous: segments,
                incoming: translated,
                incomingOffset: 0
            )
        }
        return MetaFileTranscriptionResult(segments: segments, billedSeconds: billedSeconds)
    }

    private func upload(wavData: Data, config: STTSessionConfig) async throws -> MetaFileResponse {
        for attempt in 0...1 {
            do {
                return try await performUpload(wavData: wavData, config: config)
            } catch let error as MetaTranscriptionError {
                guard attempt == 0, shouldRetry(error) else { throw error }
                // Meta documents retryable 429 and 5xx file failures. A short
                // bounded delay avoids a retry loop and preserves the local fallback.
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw MetaTranscriptionError.backend("Meta file transcription exhausted its retry")
    }

    private func performUpload(wavData: Data, config: STTSessionConfig) async throws -> MetaFileResponse {
        let boundary = "CallNotesMeta-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(boundary: boundary, wavData: wavData, config: config)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MetaTranscriptionError.unexpectedResponse("Meta returned a non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(MetaFileErrorResponse.self, from: data))?.error?.message
                    ?? "Meta transcription failed (HTTP \(http.statusCode))"
                throw MetaTranscriptionError.fromHTTP(status: http.statusCode, message: message)
            }
            if let error = try? JSONDecoder().decode(MetaFileErrorResponse.self, from: data),
                let message = error.error?.message
            {
                throw MetaTranscriptionError.backend(message)
            }
            do {
                return try JSONDecoder().decode(MetaFileResponse.self, from: data)
            } catch {
                throw MetaTranscriptionError.unexpectedResponse("Meta returned an invalid transcript response")
            }
        } catch let error as MetaTranscriptionError {
            throw error
        } catch {
            throw MetaTranscriptionError.transport(error.localizedDescription)
        }
    }

    private func shouldRetry(_ error: MetaTranscriptionError) -> Bool {
        switch error {
        case .quotaExceeded, .backend:
            true
        default:
            false
        }
    }

    private func multipartBody(boundary: String, wavData: Data, config: STTSessionConfig) throws -> Data {
        struct RequestSettings: Encodable {
            let model: String
            let audioEncoding: String
            let mode: String
            let keywords: [String]
            let languageBias: [String]
        }
        let settings = RequestSettings(
            model: MetaTranscriptionConfiguration.modelID,
            audioEncoding: "WAV",
            mode: "DIARIZATION",
            keywords: configuration.keywords + config.customVocabulary,
            languageBias: configuration.languageBias
        )
        let settingsData = (try? JSONEncoder().encode(settings)) ?? Data("{}".utf8)
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"request\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(settingsData)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"callnotes.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n--\(boundary)--\r\n")
        try MetaFileLimits.validate(
            body.count,
            maximum: MetaFileLimits.maximumMultipartBytes,
            message: "The Meta multipart request exceeds the request limit"
        )
        return body
    }

    private func fileSize(of url: URL) throws -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw MetaTranscriptionError.invalidWAV("The selected audio file could not be read")
            }
            return size
        } catch let error as MetaTranscriptionError {
            throw error
        } catch {
            throw MetaTranscriptionError.invalidWAV("The selected audio file could not be read")
        }
    }
}

public struct MetaFileTranscriptionResult: Sendable, Equatable {
    public var segments: [RawSegment]
    public var billedSeconds: Int

    public init(segments: [RawSegment], billedSeconds: Int) {
        self.segments = segments
        self.billedSeconds = billedSeconds
    }
}

private struct MetaFileResponse: Decodable {
    struct Turn: Decodable {
        let turnId: Int
        let startMs: Int
        let endMs: Int
        let transcript: String
        let speaker: String?
    }

    let sessionId: String
    let transcript: String
    let audioDurationMs: Int
    let turns: [Turn]

    func rawSegments(offset: TimeInterval) -> [RawSegment] {
        if turns.isEmpty {
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [RawSegment(
                start: offset,
                end: offset + Double(audioDurationMs) / 1_000,
                text: transcript,
                speakerTag: nil,
                channel: .mixed
            )]
        }
        return turns.map { turn in
            RawSegment(
                start: offset + Double(turn.startMs) / 1_000,
                end: offset + Double(turn.endMs) / 1_000,
                text: turn.transcript,
                speakerTag: turn.speaker,
                channel: .mixed
            )
        }
    }
}

private struct MetaFileErrorResponse: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody?
}

/// Minimal RIFF/WAVE reader/writer for Meta's narrow PCM requirement.
struct MetaWAV: Sendable {
    let sampleRate: Int
    let pcm: Data

    var frameCount: Int { pcm.count / 2 }

    static func read(fileURL: URL) throws -> MetaWAV {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MetaTranscriptionError.invalidWAV("The selected audio file could not be read")
        }
        guard data.count >= 44, data.ascii(at: 0, count: 4) == "RIFF", data.ascii(at: 8, count: 4) == "WAVE" else {
            throw MetaTranscriptionError.invalidWAV("Meta requires a RIFF/WAVE file")
        }
        var offset = 12
        var sampleRate: Int?
        var isMonoPCM16 = false
        var pcm: Data?
        while offset + 8 <= data.count {
            let identifier = data.ascii(at: offset, count: 4)
            let length = Int(data.uint32LE(at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd <= data.count else {
                throw MetaTranscriptionError.invalidWAV("The WAV file is truncated")
            }
            if identifier == "fmt ", length >= 16 {
                let format = data.uint16LE(at: payloadStart)
                let channels = data.uint16LE(at: payloadStart + 2)
                sampleRate = Int(data.uint32LE(at: payloadStart + 4))
                let bitsPerSample = data.uint16LE(at: payloadStart + 14)
                isMonoPCM16 = format == 1 && channels == 1 && bitsPerSample == 16
            } else if identifier == "data" {
                pcm = data.subdata(in: payloadStart..<payloadEnd)
            }
            offset = payloadEnd + (length % 2)
        }
        guard isMonoPCM16, let sampleRate, let pcm, [16_000, 24_000].contains(sampleRate), pcm.count.isMultiple(of: 2) else {
            throw MetaTranscriptionError.invalidWAV("Meta requires mono signed-16-bit WAV at 16 kHz or 24 kHz")
        }
        return MetaWAV(sampleRate: sampleRate, pcm: pcm)
    }

    func data(for chunk: MetaFileChunk) throws -> Data {
        let start = chunk.startFrame * 2
        let end = start + chunk.frameCount * 2
        guard start >= 0, end <= pcm.count else {
            throw MetaTranscriptionError.invalidWAV("The requested WAV chunk is outside the source audio")
        }
        let payload = pcm.subdata(in: start..<end)
        var wav = Data("RIFF".utf8)
        wav.appendUInt32LE(UInt32(36 + payload.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendUInt32LE(16)
        wav.appendUInt16LE(1)
        wav.appendUInt16LE(1)
        wav.appendUInt32LE(UInt32(sampleRate))
        wav.appendUInt32LE(UInt32(sampleRate * 2))
        wav.appendUInt16LE(2)
        wav.appendUInt16LE(16)
        wav.append(Data("data".utf8))
        wav.appendUInt32LE(UInt32(payload.count))
        wav.append(payload)
        return wav
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, offset + count <= self.count else { return nil }
        return String(data: subdata(in: offset..<(offset + count)), encoding: .ascii)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
