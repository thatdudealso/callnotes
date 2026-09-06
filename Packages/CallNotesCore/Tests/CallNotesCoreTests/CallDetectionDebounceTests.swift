import Foundation
import Testing

@testable import CallNotesCore

@Suite struct CallDetectionDebounceTests {
    @Test func bothSignalsForFiveSecondsStartsRecording() {
        var debounce = CallDetectionDebounce()
        var snapshot = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: true))
        #expect(snapshot.phase == .pendingStart)
        #expect(snapshot.isCapturing)
        #expect(!snapshot.isCommittedRecording)

        snapshot = debounce.tick(.init(now: 4.9, micActive: true, callProcessAlive: true))
        #expect(snapshot.phase == .pendingStart)

        snapshot = debounce.tick(.init(now: 5.0, micActive: true, callProcessAlive: true))
        #expect(snapshot.phase == .recording)
        #expect(snapshot.isCommittedRecording)
        #expect(!snapshot.isManual)
    }

    @Test func calendarArmShortensStartToOneSecond() {
        var debounce = CallDetectionDebounce()
        _ = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: true, calendarArmed: true))
        let snapshot = debounce.tick(
            .init(now: 1.0, micActive: true, callProcessAlive: true, calendarArmed: true)
        )
        #expect(snapshot.phase == .recording)
    }

    @Test func droppingASignalDuringPendingStartResets() {
        var debounce = CallDetectionDebounce()
        _ = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: true))
        let snapshot = debounce.tick(.init(now: 1, micActive: false, callProcessAlive: true))
        #expect(snapshot.phase == .idle)
        #expect(!snapshot.isCapturing)
    }

    @Test func eitherSignalFalseForFiveSecondsStops() {
        var debounce = CallDetectionDebounce()
        _ = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: true))
        _ = debounce.tick(.init(now: 5, micActive: true, callProcessAlive: true))

        var snapshot = debounce.tick(.init(now: 6, micActive: false, callProcessAlive: true))
        #expect(snapshot.phase == .pendingStop)
        #expect(snapshot.isCommittedRecording)

        snapshot = debounce.tick(.init(now: 10.9, micActive: false, callProcessAlive: true))
        #expect(snapshot.phase == .pendingStop)

        snapshot = debounce.tick(.init(now: 11, micActive: false, callProcessAlive: true))
        #expect(snapshot.phase == .idle)
        #expect(!snapshot.isCapturing)
    }

    @Test func signalsReturningDuringPendingStopKeepRecording() {
        var debounce = CallDetectionDebounce()
        _ = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: true))
        _ = debounce.tick(.init(now: 5, micActive: true, callProcessAlive: true))
        _ = debounce.tick(.init(now: 6, micActive: false, callProcessAlive: true))
        let snapshot = debounce.tick(.init(now: 7, micActive: true, callProcessAlive: true))
        #expect(snapshot.phase == .recording)
    }

    @Test func manualStartRecordsWithoutCallProcess() {
        var debounce = CallDetectionDebounce()
        let snapshot = debounce.tick(
            .init(now: 0, micActive: true, callProcessAlive: false, manualStart: true)
        )
        #expect(snapshot.phase == .recording)
        #expect(snapshot.isManual)
        #expect(snapshot.isCommittedRecording)
    }

    @Test func manualRecordingIgnoresDroppedAutoSignals() {
        var debounce = CallDetectionDebounce()
        _ = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: false, manualStart: true))
        let snapshot = debounce.tick(.init(now: 3, micActive: false, callProcessAlive: false))
        #expect(snapshot.phase == .recording)
        #expect(snapshot.isManual)
    }

    @Test func manualStopEndsImmediately() {
        var debounce = CallDetectionDebounce()
        _ = debounce.tick(.init(now: 0, micActive: true, callProcessAlive: true))
        _ = debounce.tick(.init(now: 5, micActive: true, callProcessAlive: true))
        let snapshot = debounce.tick(
            .init(now: 6, micActive: true, callProcessAlive: true, manualStop: true)
        )
        #expect(snapshot.phase == .idle)
    }
}