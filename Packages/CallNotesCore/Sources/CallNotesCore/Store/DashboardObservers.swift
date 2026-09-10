import Foundation

/// Shared fan-out for `CallStore.dashboardChanges()`. Owning it in one place keeps
/// the buffering policy and the termination cleanup identical for every store.
struct DashboardObservers {
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    mutating func register(cleanup: @escaping @Sendable (UUID) -> Void) -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { _ in cleanup(id) }
        continuations[id] = continuation
        return stream
    }

    mutating func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func notify() {
        for continuation in continuations.values {
            continuation.yield()
        }
    }
}
