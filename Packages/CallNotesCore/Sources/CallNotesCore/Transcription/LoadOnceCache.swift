import Foundation

/// Loads an expensive value once and shares it with every caller. Concurrent
/// callers join the in-flight load; a failed load is not cached, so the next
/// caller retries.
actor LoadOnceCache<Value: Sendable> {
    private let load: @Sendable () async throws -> Value
    private var cached: Value?
    private var inFlight: Task<Value, Error>?

    init(load: @escaping @Sendable () async throws -> Value) {
        self.load = load
    }

    func value() async throws -> Value {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        let task = Task { [load] in try await load() }
        inFlight = task
        defer { inFlight = nil }
        let value = try await task.value
        cached = value
        return value
    }
}
