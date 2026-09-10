import Foundation

/// Offline stand-in for Meta file transcription. Live Meta calls fail with
/// billing_not_configured until the captain's tenant is enabled; imports still
/// exercise the chunking, stitching, store, and notes path through this harness.
public struct SimulatedMetaFileProvider: MetaFileTranscribing {
    public var segments: [RawSegment]
    public var billedSeconds: Int
    public var error: (any Error)?
    /// Captures each file the harness was asked to transcribe so tests can
    /// prove the Meta import path was selected without hitting the network.
    public var onTranscribe: (@Sendable (URL) -> Void)?

    public init(
        segments: [RawSegment],
        billedSeconds: Int = 0,
        error: (any Error)? = nil,
        onTranscribe: (@Sendable (URL) -> Void)? = nil
    ) {
        self.segments = segments
        self.billedSeconds = billedSeconds
        self.error = error
        self.onTranscribe = onTranscribe
    }

    public func transcribeWithReceipt(
        fileURL: URL,
        config: STTSessionConfig
    ) async throws -> MetaFileTranscriptionResult {
        _ = config
        onTranscribe?(fileURL)
        if let error { throw error }
        return MetaFileTranscriptionResult(segments: segments, billedSeconds: billedSeconds)
    }
}

/// Seam used by file imports so tests inject the simulated Meta harness.
public protocol MetaFileTranscribing: Sendable {
    func transcribeWithReceipt(
        fileURL: URL,
        config: STTSessionConfig
    ) async throws -> MetaFileTranscriptionResult
}

extension MetaFileProvider: MetaFileTranscribing {}
