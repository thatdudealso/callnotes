import AppKit
import CallNotesCore
import CoreAudio
import Foundation
import os

/// Infers an in-progress Mac call from mic-running + FaceTime/Phone process
/// state, with optional EventKit arm and a manual start/stop override.
@MainActor
final class CallDetector {
    struct Status: Equatable {
        var snapshot: CallDetectionSnapshot
        var micActive: Bool
        var callProcessAlive: Bool
        var calendarArmed: Bool
        var matchingProcessObjectIDs: [AudioObjectID]
        var matchingBundleIDs: [String]
    }

    let identityStore: CallAppIdentityStore
    var onStatusChange: ((Status) -> Void)?

    private var debounce = CallDetectionDebounce()
    private var timer: Timer?
    private let calendar = CalendarArmSignal()
    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "CallDetector")
    private var startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private(set) var latest = Status(
        snapshot: CallDetectionSnapshot(phase: .idle, isCapturing: false, isCommittedRecording: false, isManual: false),
        micActive: false,
        callProcessAlive: false,
        calendarArmed: false,
        matchingProcessObjectIDs: [],
        matchingBundleIDs: []
    )

    init(identityStore: CallAppIdentityStore = CallAppIdentityStore()) {
        self.identityStore = identityStore
    }

    func start() {
        guard timer == nil else { return }
        identityStore.observe()
        Task { await calendar.requestAccessIfNeeded() }
        let timer = Timer.scheduledTimer(withTimeInterval: AudioConstants.detectorPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func manualStart() {
        tick(manualStart: true, manualStop: false)
    }

    func manualStop() {
        tick(manualStart: false, manualStop: true)
    }

    private func poll() {
        identityStore.observe()
        tick(manualStart: false, manualStop: false)
    }

    private func tick(manualStart: Bool, manualStop: Bool) {
        let micActive = AudioProcessEnumerator.defaultInputIsRunningSomewhere()
        let processes = (try? AudioProcessEnumerator.list()) ?? []
        let runningApps = NSWorkspace.shared.runningApplications
        let observed = identityStore.bundleIDs

        let matchingApps = runningApps.compactMap { app -> String? in
            guard let id = app.bundleIdentifier, observed.contains(id) else { return nil }
            return id
        }
        let matchingProcesses = processes.filter { process in
            guard let id = process.bundleID else { return false }
            return observed.contains(id)
        }
        let producingOutput = matchingProcesses.contains(where: \.isRunningOutput)
        let callProcessAlive = !matchingApps.isEmpty || producingOutput
        let calendarArmed = calendar.isArmed()

        let sample = CallDetectionSample(
            now: ProcessInfo.processInfo.systemUptime - startedAt,
            micActive: micActive,
            callProcessAlive: callProcessAlive,
            calendarArmed: calendarArmed,
            manualStart: manualStart,
            manualStop: manualStop
        )
        let snapshot = debounce.tick(sample)
        let status = Status(
            snapshot: snapshot,
            micActive: micActive,
            callProcessAlive: callProcessAlive,
            calendarArmed: calendarArmed,
            matchingProcessObjectIDs: matchingProcesses.map(\.objectID).sorted(),
            matchingBundleIDs: Array(Set(matchingApps + matchingProcesses.compactMap(\.bundleID))).sorted()
        )
        let changed = status != latest
        latest = status
        if changed {
            logger.debug("detector \(String(describing: snapshot.phase), privacy: .public) mic=\(micActive) call=\(callProcessAlive)")
            onStatusChange?(status)
        }
    }
}