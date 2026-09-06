import Foundation
import Synchronization

/// Interleaved stereo Int16 ring (L = near, R = far) covering the 30 s
/// late-engine window and the detection debounce pre-roll.
public final class AudioRingBuffer: Sendable {
    public let frameCapacity: Int
    public let sampleRate: Int

    private struct Storage: Sendable {
        var samples: [Int16]
        var writeFrame: Int
        var filledFrames: Int
    }

    private let storage: Mutex<Storage>

    public init(
        seconds: TimeInterval = AudioConstants.ringBufferSeconds,
        sampleRate: Int = AudioConstants.localSampleRate
    ) {
        let frames = max(1, Int((seconds * Double(sampleRate)).rounded(.up)))
        self.frameCapacity = frames
        self.sampleRate = sampleRate
        self.storage = Mutex(
            Storage(
                samples: Array(repeating: 0, count: frames * AudioConstants.captureChannels),
                writeFrame: 0,
                filledFrames: 0
            )
        )
    }

    public var availableFrames: Int {
        storage.withLock { $0.filledFrames }
    }

    /// Writes `frameCount` interleaved stereo frames. Extra samples beyond
    /// `frameCount * 2` are ignored; a short buffer writes what it has.
    public func writeInterleaved(_ interleaved: UnsafeBufferPointer<Int16>) {
        let channels = AudioConstants.captureChannels
        let incomingFrames = interleaved.count / channels
        guard incomingFrames > 0 else { return }

        storage.withLock { state in
            var src = 0
            for _ in 0..<incomingFrames {
                let dest = state.writeFrame * channels
                state.samples[dest] = interleaved[src]
                state.samples[dest + 1] = interleaved[src + 1]
                src += channels
                state.writeFrame += 1
                if state.writeFrame == frameCapacity {
                    state.writeFrame = 0
                }
                if state.filledFrames < frameCapacity {
                    state.filledFrames += 1
                }
            }
        }
    }

    public func writeInterleaved(_ interleaved: [Int16]) {
        interleaved.withUnsafeBufferPointer { writeInterleaved($0) }
    }

    public func write(near: [Int16], far: [Int16]) {
        let frames = min(near.count, far.count)
        guard frames > 0 else { return }
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[i * 2] = near[i]
            interleaved[i * 2 + 1] = far[i]
        }
        writeInterleaved(interleaved)
    }

    /// Oldest-to-newest interleaved snapshot of the currently filled window.
    public func snapshot() -> [Int16] {
        storage.withLock { state in
            let channels = AudioConstants.captureChannels
            let filled = state.filledFrames
            guard filled > 0 else { return [Int16]() }
            var out = [Int16](repeating: 0, count: filled * channels)
            let startFrame = (state.writeFrame - filled + frameCapacity) % frameCapacity
            for i in 0..<filled {
                let srcFrame = (startFrame + i) % frameCapacity
                let src = srcFrame * channels
                let dest = i * channels
                out[dest] = state.samples[src]
                out[dest + 1] = state.samples[src + 1]
            }
            return out
        }
    }

    public func reset() {
        storage.withLock { state in
            state.samples = Array(repeating: 0, count: frameCapacity * AudioConstants.captureChannels)
            state.writeFrame = 0
            state.filledFrames = 0
        }
    }
}