import Foundation

/// Result of a provider or dependency readiness probe.
public enum ProviderHealth: Sendable, Equatable {
    case healthy
    case degraded(reason: String)
    case unavailable(reason: String)

    public var isUsable: Bool {
        switch self {
        case .healthy, .degraded: return true
        case .unavailable: return false
        }
    }
}

/// One dependency the app health-checks at startup and on demand
/// (Postgres, Ollama + pinned models, disk, Meta reachability).
public struct DependencyCheck: Sendable, Equatable {
    public var name: String
    public var health: ProviderHealth

    public init(name: String, health: ProviderHealth) {
        self.name = name
        self.health = health
    }
}
