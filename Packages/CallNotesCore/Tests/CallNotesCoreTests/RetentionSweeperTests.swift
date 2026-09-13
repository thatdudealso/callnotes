import Foundation
import Testing

@testable import CallNotesCore

@Suite struct RetentionSweeperTests {
    @Test func keepForeverDeletesNothing() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let call = try await seededCall(store: store, root: root, ageDays: 400, bytes: 64)
        let result = try await RetentionSweeper(policy: RetentionPolicy()).sweep(store: store, now: Date())
        #expect(result.deletedCallIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: call.audioPath))
        #expect(try await store.fetchCall(id: call.id) != nil)
    }

    @Test func deleteAudioRemovesFileAndKeepsTranscript() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let call = try await seededCall(store: store, root: root, ageDays: 40, bytes: 128)
        let policy = RetentionPolicy(mode: .deleteAudioKeepTranscript, days: 30)
        let result = try await RetentionSweeper(policy: policy).sweep(store: store, now: Date())
        #expect(result.deletedAudioPaths == [call.audioPath])
        #expect(result.reclaimedBytes == 128)
        #expect(!FileManager.default.fileExists(atPath: call.audioPath))
        let kept = try #require(await store.fetchCall(id: call.id))
        #expect(kept.audioPath.isEmpty)
        #expect(try await store.fetchSegments(callID: call.id, provider: .appleSpeech).map(\.text) == ["hello"])
    }

    @Test func deleteAllRemovesFileAndCallRow() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let call = try await seededCall(store: store, root: root, ageDays: 10, bytes: 32)
        let policy = RetentionPolicy(mode: .deleteAll, days: 7)
        let result = try await RetentionSweeper(policy: policy).sweep(store: store, now: Date())
        #expect(result.deletedCallIDs == [call.id])
        #expect(!FileManager.default.fileExists(atPath: call.audioPath))
        #expect(try await store.fetchCall(id: call.id) == nil)
        #expect(try await store.fetchSegments(callID: call.id, provider: .appleSpeech).isEmpty)
    }

    @Test func recentCallsAreKept() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let call = try await seededCall(store: store, root: root, ageDays: 2, bytes: 16)
        let policy = RetentionPolicy(mode: .deleteAll, days: 7)
        let result = try await RetentionSweeper(policy: policy).sweep(store: store, now: Date())
        #expect(result.deletedCallIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: call.audioPath))
    }

    @Test func activeAndInProgressCallsAreNotSwept() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let statuses: [CallStatus] = [.recording, .uploaded, .transcribing, .transcribed]
        var calls: [Call] = []
        for status in statuses {
            let call = try await seededCall(
                store: store,
                root: root,
                ageDays: 40,
                bytes: 16,
                status: status,
                isActive: status == .recording
            )
            calls.append(call)
        }

        let result = try await RetentionSweeper(
            policy: RetentionPolicy(mode: .deleteAll, days: 30)
        ).sweep(store: store, now: Date())

        #expect(result.deletedCallIDs.isEmpty)
        for call in calls {
            #expect(FileManager.default.fileExists(atPath: call.audioPath))
            #expect(try await store.fetchCall(id: call.id) != nil)
        }
    }

    private func scratchRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seededCall(
        store: MemoryStore,
        root: URL,
        ageDays: Int,
        bytes: Int,
        status: CallStatus = .notesReady,
        isActive: Bool = false
    ) async throws -> Call {
        let audio = root.appendingPathComponent("\(UUID().uuidString).caf")
        try Data(repeating: 1, count: bytes).write(to: audio)
        let started = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        var call = Call(
            source: .macManual,
            startedAt: started,
            endedAt: isActive ? nil : started.addingTimeInterval(30),
            durationSec: 30,
            audioPath: audio.path,
            sttProvider: .appleSpeech,
            status: status
        )
        try await store.upsertCall(call)
        try await store.replaceSegments(
            callID: call.id,
            provider: .appleSpeech,
            [
                Segment(
                    callID: call.id,
                    seq: 0,
                    startSec: 0,
                    endSec: 1,
                    channel: .near,
                    text: "hello",
                    provider: .appleSpeech
                )
            ]
        )
        call = try #require(await store.fetchCall(id: call.id))
        return call
    }
}
