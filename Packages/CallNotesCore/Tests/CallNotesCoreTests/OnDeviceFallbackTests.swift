import Foundation
import Testing

@testable import CallNotesCore

@Suite struct OnDeviceFallbackTests {
    @Test func transcribesOnlyWhenEnabledAndMacUnreachable() {
        #expect(
            OnDeviceFallback.shouldTranscribe(
                isEnabled: true,
                isMacReachable: false
            )
        )
        #expect(
            !OnDeviceFallback.shouldTranscribe(
                isEnabled: false,
                isMacReachable: false
            )
        )
        #expect(
            !OnDeviceFallback.shouldTranscribe(
                isEnabled: true,
                isMacReachable: true
            )
        )
    }

    @Test func transportErrorsAreUnreachableButRefusalsAreNot() {
        #expect(OnDeviceFallback.isMacUnreachable("Could not connect to the Mac."))
        #expect(OnDeviceFallback.isMacUnreachable("The request timed out"))
        #expect(!OnDeviceFallback.isMacUnreachable("HTTP 400 from your Mac"))
        #expect(!OnDeviceFallback.isMacUnreachable("This iPhone is no longer paired with your Mac."))
        #expect(!OnDeviceFallback.isMacUnreachable(nil))
    }

    @Test func transcriberWritesLocalSegmentsFromScriptedSpeech() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-fallback-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = Data((0..<3_200).map { _ in UInt8(0) })
        try ChannelAudio.writeMonoCAF(pcm16: pcm, sampleRate: 16_000, to: url)
        let speech = ScriptedPCMTranscriber(
            near: [RawSegment(start: 0, end: 1, text: "on device", channel: .mixed)],
            far: []
        )
        let transcriber = OnDeviceFallbackTranscriber(speech: speech)
        let callID = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await transcriber.transcribe(fileURL: url, callID: callID, startedAt: started)
        #expect(result.callID == callID)
        #expect(result.segments.map(\.text) == ["on device"])
        #expect(result.provider == .appleSpeech)
    }
}
