import Foundation
import Testing

@testable import CallNotesCore

@Suite struct DiagnosticsBundleTests {
    @Test func exportOmitsAudioTranscriptAndCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DiagnosticLog.append(
            DiagnosticEvent(
                category: "capture",
                event: "started",
                metadata: ["api_key": "sk-secret-value", "callID": "not-a-secret"]
            ),
            root: root
        )
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0",
            osVersion: "macOS 26",
            storeBackend: "postgres",
            engineDefault: "local",
            consentPolicy: "tone",
            retention: "keep_forever",
            health: ["postgres": "healthy", "ollama": "healthy"],
            logLines: try DiagnosticLog.recentEvents(root: root)
        )
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        _ = try DiagnosticsBundle.export(snapshot, to: bundle)

        #expect(DiagnosticsBundle.containsForbiddenContent(in: bundle) == nil)
        let json = try String(
            contentsOf: bundle.appendingPathComponent(DiagnosticsBundle.snapshotFileName),
            encoding: .utf8
        )
        #expect(!json.lowercased().contains("sk-secret"))
        #expect(!json.contains("This is a transcript of the call"))
        let files = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
        #expect(!files.contains { ["caf", "m4a", "wav"].contains($0.pathExtension.lowercased()) })
        let exclusions = try String(
            contentsOf: bundle.appendingPathComponent(DiagnosticsBundle.exclusionsFileName),
            encoding: .utf8
        )
        for item in DiagnosticsBundle.exclusions {
            #expect(exclusions.contains(item))
        }
    }

    @Test func exportDropsTranscriptShapedLogEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-diag-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0",
            osVersion: "macOS 26",
            storeBackend: "memory",
            engineDefault: "local",
            consentPolicy: "tone",
            retention: "keep_forever",
            health: [:],
            logLines: [
                DiagnosticEvent(
                    category: "transcription",
                    event: "segment",
                    metadata: [
                        "text": "Private call transcript content",
                        "startSec": "0",
                        "endSec": "1",
                    ]
                )
            ]
        )
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        _ = try DiagnosticsBundle.export(snapshot, to: bundle)

        let json = try Data(contentsOf: bundle.appendingPathComponent(DiagnosticsBundle.snapshotFileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(DiagnosticsSnapshot.self, from: json)
        #expect(exported.logLines.isEmpty)
    }

    @Test func redactsBearerTokensInMetadata() {
        let redacted = DiagnosticLog.redact(["authorization": "Bearer abcdef", "stage": "transcription"])
        #expect(redacted["authorization"] == "<redacted>")
        #expect(redacted["stage"] == "transcription")
    }
}
