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
    private var captureTransition: Task<Void, Never>?

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

    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        capture.onMixedPCM = handler
    }

    private func handle(_ status: CallDetector.Status) {
        let phase = status.snapshot.phase
        switch (previousPhase, phase) {
        case (.idle, .pendingStart), (.idle, .recording):
            enqueueCaptureReconciliation()
        case (.pendingStart, .recording):
            enqueueCaptureReconciliation()
        case (_, .idle) where previousPhase != .idle:
            enqueueCaptureReconciliation()
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

    private func enqueueCaptureReconciliation() {
        let previousTransition = captureTransition
        captureTransition = Task { @MainActor [weak self] in
            await previousTransition?.value
            guard let self else { return }
            await reconcileCapture()
        }
    }

    private func reconcileCapture() async {
        let status = detector.latest
        guard status.snapshot.isCapturing else {
            if capture.isRunning {
                await stopCapture()
            }
            return
        }

        if !capture.isRunning {
            await startCapture(status: status)
        }
        if capture.isRunning, detector.latest.snapshot.isCommittedRecording {
            capture.beginCommittedWrite()
        }
    }

    private func startCapture(status: CallDetector.Status) async {
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
