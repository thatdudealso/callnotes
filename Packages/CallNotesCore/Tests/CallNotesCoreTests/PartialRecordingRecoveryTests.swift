import Foundation
import Testing

@testable import CallNotesCore

@Suite struct PartialRecordingRecoveryTests {
    @Test func orphanCAFBecomesUploadedCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let callID = UUID()
        let url = root.appendingPathComponent("\(callID.uuidString).caf")
        let near = (0..<1_600).map { Int16($0) }
        let far = [Int16](repeating: 0, count: 1_600)
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        writer.abandonWithoutClosing()

        let store = MemoryStore()
        let recovered = try await PartialRecordingRecovery.recover(audioDirectory: root, store: store)
        let item = try #require(recovered.first)
        #expect(item.call.id == callID)
        #expect(item.call.status == .uploaded)
        #expect(item.createdCall)
        #expect(try await store.fetchCall(id: callID)?.audioPath == url.resolvingSymlinksInPath().path)
        let channels = try StereoCAFReader.read(url)
        #expect(channels.near == near)
    }

    @Test func strandedRecordingWithAudioIsQueuedInsteadOfFailed() {
        var call = Call(
            source: .macManual,
            startedAt: Date(),
            audioPath: "/tmp/partial.caf",
            sttProvider: .appleSpeech,
            status: .recording
        )
        let closed = StrandedRecordingRepair.closed(call, lastSegmentEndSec: nil, hasRecoverableAudio: true)
        #expect(closed.status == .uploaded)
        #expect(closed.errorStage == nil)
        call.audioPath = ""
        let failed = StrandedRecordingRepair.closed(call, lastSegmentEndSec: nil, hasRecoverableAudio: false)
        #expect(failed.status == .failed)
        #expect(failed.errorStage == PipelineStage.capture.rawValue)
    }

    @Test func recoveredAudioIsProcessableByTheSpine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-partial-spine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let callID = UUID()
        let url = root.appendingPathComponent("\(callID.uuidString).caf")
        let frames = 3_200
        let near = (0..<frames).map { Int16($0 % 50) }
        let far = [Int16](repeating: 100, count: frames)
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        writer.abandonWithoutClosing()
        _ = try CAFHeaderRepair.repairIfNeeded(url)

        let store = MemoryStore()
        let call = Call(
            id: callID,
            source: .macManual,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech,
            status: .recording
        )
        try await store.upsertCall(call)
        let spine = LocalTranscriptionSpine(
            speech: ScriptedPCMTranscriber(
                near: [RawSegment(start: 0, end: 0.2, text: "recovered near", channel: .near)],
                far: [RawSegment(start: 0.2, end: 0.4, text: "recovered far", channel: .far)]
            ),
            diarizer: ScriptedDiarizer(clusters: [
                DiarizedCluster(key: "A", ranges: [0.2...0.4])
            ]),
            store: store
        )
        let processed = try await spine.process(cafURL: url, call: call, profiles: [])
        #expect(processed.call.status == .transcribed)
        let texts = try await store.fetchSegments(callID: callID, provider: .appleSpeech).map(\.text)
        #expect(texts.contains("recovered near"))
        #expect(texts.contains("recovered far"))
    }

    @Test func finishedCallsAreNotRequeued() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-partial-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let callID = UUID()
        let url = root.appendingPathComponent("\(callID.uuidString).caf")
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: [Int16](repeating: 1, count: 1_600), far: [Int16](repeating: 0, count: 1_600))
        writer.close()
        let store = MemoryStore()
        try await store.upsertCall(
            Call(
                id: callID,
                source: .macManual,
                startedAt: Date(),
                audioPath: url.path,
                sttProvider: .appleSpeech,
                status: .notesReady
            )
        )
        let recovered = try await PartialRecordingRecovery.recover(audioDirectory: root, store: store)
        #expect(recovered.isEmpty)
        #expect(try await store.fetchCall(id: callID)?.status == .notesReady)
    }

    @Test func failedNotesCallsAreNotRequeued() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-partial-failed-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let callID = UUID()
        let url = root.appendingPathComponent("\(callID.uuidString).caf")
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: [Int16](repeating: 1, count: 1_600), far: [Int16](repeating: 0, count: 1_600))
        writer.close()

        let store = MemoryStore()
        let call = Call(
            id: callID,
            source: .macManual,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech,
            status: .failed,
            error: "Notes generation failed",
            errorStage: PipelineStage.notes.rawValue
        )
        try await store.upsertCall(call)

        let recovered = try await PartialRecordingRecovery.recover(audioDirectory: root, store: store)
        let persisted = try await store.fetchCall(id: callID)
        #expect(recovered.isEmpty)
        #expect(persisted?.status == .failed)
        #expect(persisted?.error == "Notes generation failed")
        #expect(persisted?.errorStage == PipelineStage.notes.rawValue)
    }
}
