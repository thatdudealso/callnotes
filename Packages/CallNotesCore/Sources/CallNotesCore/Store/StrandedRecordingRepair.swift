import Foundation

/// A call row left in `recording` by a crash or force quit has no end, so every
/// duration derived from it grows with wall-clock time forever. Closing it out
/// against its last known timestamp keeps talk time, periods and contacts honest.
public enum StrandedRecordingRepair {
    public static func isStranded(_ call: Call, liveCallID: UUID?) -> Bool {
        call.status == .recording && call.id != liveCallID
    }

    public static func closed(_ call: Call, lastSegmentEndSec: TimeInterval?) -> Call {
        var repaired = call
        let knownEnds = [
            lastSegmentEndSec,
            call.endedAt.map { $0.timeIntervalSince(call.startedAt) },
            call.durationSec.map(TimeInterval.init),
        ].compactMap { $0 }.filter { $0 > 0 }
        let elapsed = knownEnds.max() ?? 0
        repaired.endedAt = call.startedAt.addingTimeInterval(elapsed)
        repaired.durationSec = Int(elapsed.rounded(.down))
        if knownEnds.isEmpty {
            repaired.status = .failed
            repaired.error = "Recording did not finish."
            repaired.errorStage = "capture"
        } else {
            repaired.status = .transcribed
        }
        return repaired
    }
}
