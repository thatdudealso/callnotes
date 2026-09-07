import Foundation
import PostgresNIO

/// Connection settings for a Postgres store. Automatic local discovery uses
/// `localCandidates()` so only the dedicated CallNotes instance is probed.
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
        database: String = "callnotes",
        homebrewPrefixes: [String]? = nil
    ) -> [StoreConfiguration] {
        let prefixes = homebrewPrefixes ?? resolvedHomebrewPrefixes()
        let sockets = prefixes.map {
            "\($0)/var/callnotes-postgresql@18/socket/.s.PGSQL.5433"
        }
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

    private static func resolvedHomebrewPrefixes() -> [String] {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let environmentPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
            !environmentPrefix.isEmpty
        {
            prefixes.append(environmentPrefix)
        }
        if let installedPrefix = installedHomebrewPrefix() {
            prefixes.append(installedPrefix)
        }
        return Array(Set(prefixes)).sorted()
    }

    private static func installedHomebrewPrefix() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["brew", "--prefix"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
            let prefix = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prefix.isEmpty
        else {
            return nil
        }
        return prefix
    }
}
