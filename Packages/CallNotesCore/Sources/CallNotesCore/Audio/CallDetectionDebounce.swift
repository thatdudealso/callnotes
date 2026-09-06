import Foundation

/// Auto-record detector phase. Hardware capture runs whenever `isCapturing`
/// is true so the ring buffer covers the start-debounce window.
public enum CallDetectionPhase: Equatable, Sendable {
    case idle
    case pendingStart
    case recording
    case pendingStop
}

/// Snapshot returned from each debounce tick.
public struct CallDetectionSnapshot: Equatable, Sendable {
    public var phase: CallDetectionPhase
    /// Pre-roll or committed capture should be running.
    public var isCapturing: Bool
    /// CAF writing / user-visible REC is active.
    public var isCommittedRecording: Bool
    public var isManual: Bool

    public init(
        phase: CallDetectionPhase,
        isCapturing: Bool,
        isCommittedRecording: Bool,
        isManual: Bool
    ) {
        self.phase = phase
        self.isCapturing = isCapturing
        self.isCommittedRecording = isCommittedRecording
        self.isManual = isManual
    }
}

/// One sample of detector inputs. `now` is a monotonic seconds clock so tests
/// can drive time without sleeping. `manualStart` / `manualStop` are
/// edge-triggered: pass true only on the tick they happen.
public struct CallDetectionSample: Equatable, Sendable {
    public var now: TimeInterval
    public var micActive: Bool
    public var callProcessAlive: Bool
    public var calendarArmed: Bool
    public var manualStart: Bool
    public var manualStop: Bool

    public init(
        now: TimeInterval,
        micActive: Bool,
        callProcessAlive: Bool,
        calendarArmed: Bool = false,
        manualStart: Bool = false,
        manualStop: Bool = false
    ) {
        self.now = now
        self.micActive = micActive
        self.callProcessAlive = callProcessAlive
        self.calendarArmed = calendarArmed
        self.manualStart = manualStart
        self.manualStop = manualStop
    }

    public var bothAutoSignals: Bool { micActive && callProcessAlive }
}

/// Pure debounce for Mac call detection (plan section 4.1).
///
/// Auto-start: both mic-running and call-process-alive must stay true for 5 s
/// (1 s when a calendar event arms the detector). Auto-stop: either signal
/// false for 5 s. Manual start/stop override immediately; manual start is
/// allowed without a call process (in-person mic-only recording).
public struct CallDetectionDebounce: Sendable {
    public var startDebounce: TimeInterval
    public var armedStartDebounce: TimeInterval
    public var stopDebounce: TimeInterval

    private var phase: CallDetectionPhase = .idle
    private var isManual = false
    private var phaseEnteredAt: TimeInterval = 0

    public init(
        startDebounce: TimeInterval = AudioConstants.startDebounceSeconds,
        armedStartDebounce: TimeInterval = AudioConstants.armedStartDebounceSeconds,
        stopDebounce: TimeInterval = AudioConstants.stopDebounceSeconds
    ) {
        self.startDebounce = startDebounce
        self.armedStartDebounce = armedStartDebounce
        self.stopDebounce = stopDebounce
    }

    public mutating func tick(_ sample: CallDetectionSample) -> CallDetectionSnapshot {
        if sample.manualStop {
            enter(.idle, at: sample.now, manual: false)
            return snapshot()
        }

        if sample.manualStart {
            enter(.recording, at: sample.now, manual: true)
            return snapshot()
        }

        switch phase {
        case .idle:
            if sample.bothAutoSignals {
                enter(.pendingStart, at: sample.now, manual: false)
            }

        case .pendingStart:
            if !sample.bothAutoSignals {
                enter(.idle, at: sample.now, manual: false)
            } else if sample.now - phaseEnteredAt >= startWindow(calendarArmed: sample.calendarArmed) {
                enter(.recording, at: sample.now, manual: false)
            }

        case .recording:
            if !isManual && !sample.bothAutoSignals {
                enter(.pendingStop, at: sample.now, manual: false)
            }

        case .pendingStop:
            if sample.bothAutoSignals {
                enter(.recording, at: sample.now, manual: false)
            } else if sample.now - phaseEnteredAt >= stopDebounce {
                enter(.idle, at: sample.now, manual: false)
            }
        }

        return snapshot()
    }

    public func currentSnapshot() -> CallDetectionSnapshot { snapshot() }

    private mutating func enter(_ newPhase: CallDetectionPhase, at now: TimeInterval, manual: Bool) {
        phase = newPhase
        phaseEnteredAt = now
        isManual = manual && newPhase == .recording
    }

    private func startWindow(calendarArmed: Bool) -> TimeInterval {
        calendarArmed ? armedStartDebounce : startDebounce
    }

    private func snapshot() -> CallDetectionSnapshot {
        CallDetectionSnapshot(
            phase: phase,
            isCapturing: phase != .idle,
            isCommittedRecording: phase == .recording || phase == .pendingStop,
            isManual: isManual
        )
    }
}