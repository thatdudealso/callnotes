import Foundation
import Testing

@testable import CallNotesCore

@Suite struct AudioRingBufferTests {
    @Test func writesAndReadsInterleavedStereoInOrder() {
        let buffer = AudioRingBuffer(seconds: 1, sampleRate: 8)
        buffer.write(near: [1, 3, 5], far: [2, 4, 6])
        #expect(buffer.availableFrames == 3)
        #expect(buffer.snapshot() == [1, 2, 3, 4, 5, 6])
    }

    @Test func overwriteDropsOldestWhenCapacityIsExceeded() {
        let buffer = AudioRingBuffer(seconds: 1, sampleRate: 2)
        buffer.write(near: [1, 3, 5], far: [2, 4, 6])
        #expect(buffer.availableFrames == 2)
        #expect(buffer.snapshot() == [3, 4, 5, 6])
    }

    @Test func resetClearsFilledWindow() {
        let buffer = AudioRingBuffer(seconds: 1, sampleRate: 4)
        buffer.write(near: [1], far: [2])
        buffer.reset()
        #expect(buffer.availableFrames == 0)
        #expect(buffer.snapshot().isEmpty)
    }

    @Test func defaultCapacityCoversThirtySecondsAtLocalRate() {
        let buffer = AudioRingBuffer()
        #expect(buffer.frameCapacity == Int(AudioConstants.ringBufferSeconds) * AudioConstants.localSampleRate)
    }
}