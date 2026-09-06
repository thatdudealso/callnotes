import Foundation
import PostgresNIO

/// Connection settings for the local Postgres instance the Mac app owns.
/// The PostgresNIO-backed store implementation arrives in Phase 2; declaring
/// the configuration here keeps the dependency surface in one place.
public struct StoreConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    public var unixSocketPath: String?

    public init(
        host: String = "127.0.0.1",
        port: Int = 5432,
        username: String = "callnotes",
        database: String = "callnotes",
        unixSocketPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.unixSocketPath = unixSocketPath
    }

    /// Builds the PostgresNIO client configuration (password comes from
    /// Keychain at runtime, never from disk). An empty password becomes `nil`
    /// so the client does not send a zero-length secret.
    public func clientConfiguration(password: String) -> PostgresClient.Configuration {
        let secret: String? = password.isEmpty ? nil : password
        if let unixSocketPath {
            return PostgresClient.Configuration(
                unixSocketPath: unixSocketPath,
                username: username,
                password: secret,
                database: database
            )
        }
        return PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: secret,
            database: database,
            tls: .disable
        )
    }

    /// Local bootstrap instances. Only known dedicated postgresql@18 sockets are
    /// used, so a machine's unrelated Postgres is never probed or migrated.
    public static func localCandidates(
        username: String = "callnotes",
        database: String = "callnotes"
    ) -> [StoreConfiguration] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sockets = [
            "/opt/homebrew/var/callnotes-postgresql@18/socket/.s.PGSQL.5433",
            "/usr/local/var/callnotes-postgresql@18/socket/.s.PGSQL.5433",
            "\(home)/Library/Application Support/CallNotes/postgresql@18/socket/.s.PGSQL.5433",
        ]
        var configs: [StoreConfiguration] = []
        for path in sockets where FileManager.default.fileExists(atPath: path) {
            configs.append(
                StoreConfiguration(
                    username: username,
                    database: database,
                    unixSocketPath: path
                )
            )
        }
        return configs
    }
}
