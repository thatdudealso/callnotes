import CallNotesCore
import Foundation
import os
import SwiftUI

/// Wires `CallDetector` to `AudioCapture` and publishes menu-bar recording state.
@MainActor
@Observable
final class CaptureCoordinator {
    private(set) var recordingState: RecordingState = .idle
    private(set) var lastCaptureURL: URL?
    private(set) var lastFarSource: AudioCapture.FarSource = .none
    private(set) var lastError: String?

    let detector = CallDetector()
    private let capture = AudioCapture()
    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "CaptureCoordinator")
    private var activeCallID: UUID?
    private var previousPhase: CallDetectionPhase = .idle

    init() {
        Task { @MainActor in
            self.start()
        }
    }

    func start() {
        detector.onStatusChange = { [weak self] status in
            self?.handle(status)
        }
        detector.start()
    }

    func toggleManual() {
        if detector.latest.snapshot.isCommittedRecording {
            detector.manualStop()
        } else {
            detector.manualStart()
        }
    }

    private func handle(_ status: CallDetector.Status) {
        let phase = status.snapshot.phase
        switch (previousPhase, phase) {
        case (.idle, .pendingStart), (.idle, .recording):
            Task { await startCapture(status: status, committed: phase == .recording) }
        case (.pendingStart, .recording):
            capture.beginCommittedWrite()
            recordingState = .recording
        case (_, .idle) where previousPhase != .idle:
            Task { await stopCapture() }
        default:
            break
        }
        if phase == .pendingStart {
            recordingState = .armed
        } else if phase == .recording || phase == .pendingStop {
            recordingState = .recording
        } else if phase == .idle, recordingState != .processing {
            recordingState = .idle
        }
        previousPhase = phase
    }

    private func startCapture(status: CallDetector.Status, committed: Bool) async {
        do {
            let callID = UUID()
            activeCallID = callID
            let url = try CallAudioPaths.cafURL(callID: callID)
            try await capture.start(
                AudioCapture.Configuration(
                    outputURL: url,
                    processObjectIDs: status.matchingProcessObjectIDs,
                    observedBundleIDs: status.matchingBundleIDs,
                    enableMicrophone: true,
                    enableVoiceProcessing: true
                )
            )
            if committed {
                capture.beginCommittedWrite()
                recordingState = .recording
            } else {
                recordingState = .armed
            }
            lastFarSource = capture.farSource
            lastError = nil
            logger.info("capture started \(url.path, privacy: .public) far=\(self.capture.farSource.rawValue, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            logger.error("capture start failed: \(error.localizedDescription, privacy: .public)")
            recordingState = .idle
            previousPhase = .idle
        }
    }

    private func stopCapture() async {
        recordingState = .processing
        do {
            lastCaptureURL = try await capture.stop()
            lastFarSource = capture.farSource
            logger.info("capture wrote \(self.lastCaptureURL?.path ?? "", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            logger.error("capture stop failed: \(error.localizedDescription, privacy: .public)")
        }
        recordingState = .idle
        activeCallID = nil
    }
}