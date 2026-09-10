import Foundation
import Testing

@testable import CallNotesCore

@Suite struct LoadOnceCacheTests {
    @Test func concurrentCallersShareASingleLoad() async throws {
        let attempts = LoadAttemptCounter()
        let cache = LoadOnceCache<Int> {
            await attempts.record()
            try? await Task.sleep(for: .milliseconds(20))
            return 7
        }

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await cache.value() }
            }
            var collected: [Int] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        #expect(values == Array(repeating: 7, count: 8))
        #expect(await attempts.count == 1)
    }

    @Test func aFailedLoadIsRetriedByTheNextCaller() async throws {
        let attempts = LoadAttemptCounter()
        let cache = LoadOnceCache<Int> {
            let attempt = await attempts.record()
            guard attempt > 1 else { throw LoadProbeError.unavailable }
            return 42
        }

        await #expect(throws: LoadProbeError.self) {
            try await cache.value()
        }
        #expect(try await cache.value() == 42)
        #expect(try await cache.value() == 42)
        #expect(await attempts.count == 2)
    }
}

private actor LoadAttemptCounter {
    private(set) var count = 0

    @discardableResult
    func record() -> Int {
        count += 1
        return count
    }
}

private enum LoadProbeError: Error {
    case unavailable
}
