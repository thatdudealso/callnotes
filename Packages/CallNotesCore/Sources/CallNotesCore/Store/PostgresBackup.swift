import Foundation

public enum PostgresBackupError: Error, Equatable, Sendable {
    case dedicatedInstanceNotFound
    case commandFailed(String)
    case restoreMismatch(String)
}

/// `pg_dump` / restore against the dedicated CallNotes PostgreSQL 18
/// instance only. Never uses port 5432 or `/tmp/.s.PGSQL.5432`.
public enum PostgresBackup: Sendable {
    public static let scratchDatabase = "callnotes_restore_verify"
    public static let role = "callnotes"
    public static let database = "callnotes"
    public static let port = 5433

    /// Peer superuser on the dedicated instance. The `callnotes` role cannot
    /// `CREATEDB`; scratch create/drop uses this account on the same socket.
    public static var adminRole: String {
        #if os(macOS)
        ProcessInfo.processInfo.userName
        #else
        role
        #endif
    }

    public struct Paths: Sendable, Equatable {
        public var socketDirectory: String
        public var binDirectory: String

        public init(socketDirectory: String, binDirectory: String) {
            self.socketDirectory = socketDirectory
            self.binDirectory = binDirectory
        }

        public var pgDump: String { binDirectory + "/pg_dump" }
        public var psql: String { binDirectory + "/psql" }
        public var createdb: String { binDirectory + "/createdb" }
        public var dropdb: String { binDirectory + "/dropdb" }
        public var pgRestore: String { binDirectory + "/pg_restore" }
    }

    public static func dedicatedPaths(
        homebrewPrefixes: [String]? = nil,
        fileManager: FileManager = .default
    ) -> Paths? {
        let prefixes = homebrewPrefixes ?? defaultPrefixes()
        for prefix in prefixes {
            let socket = "\(prefix)/var/callnotes-postgresql@18/socket/.s.PGSQL.\(port)"
            let bin = "\(prefix)/opt/postgresql@18/bin"
            if fileManager.fileExists(atPath: socket), fileManager.isExecutableFile(atPath: "\(bin)/pg_dump") {
                return Paths(
                    socketDirectory: "\(prefix)/var/callnotes-postgresql@18/socket",
                    binDirectory: bin
                )
            }
        }
        return nil
    }

    public static func dump(
        to url: URL,
        paths: Paths,
        run: (String, [String]) throws -> String = runProcess
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try run(paths.pgDump, [
            "--host", paths.socketDirectory,
            "--port", String(port),
            "--username", role,
            "--dbname", database,
            "--format", "custom",
            "--file", url.path,
            "--no-owner",
            "--no-acl",
        ])
    }

    public static func restoreScratch(
        from dumpURL: URL,
        paths: Paths,
        scratchDatabase: String = scratchDatabase,
        run: (String, [String]) throws -> String = runProcess
    ) throws {
        _ = try? run(paths.dropdb, hostArgs(paths, username: adminRole) + ["--if-exists", scratchDatabase])
        _ = try run(paths.createdb, hostArgs(paths, username: adminRole) + ["--owner", role, scratchDatabase])
        _ = try run(paths.pgRestore, [
            "--host", paths.socketDirectory,
            "--port", String(port),
            "--username", adminRole,
            "--dbname", scratchDatabase,
            "--no-owner",
            "--no-acl",
            dumpURL.path,
        ])
    }

    public static func relationCounts(
        database: String,
        paths: Paths,
        username: String = role,
        run: (String, [String]) throws -> String = runProcess
    ) throws -> [String: Int] {
        let sql = """
            SELECT relname || '=' || cnt::text FROM (
              SELECT 'calls'::text AS relname, count(*)::bigint AS cnt FROM calls
              UNION ALL SELECT 'segments', count(*) FROM segments
              UNION ALL SELECT 'notes', count(*) FROM notes
              UNION ALL SELECT 'speaker_profiles', count(*) FROM speaker_profiles
              UNION ALL SELECT 'call_speakers', count(*) FROM call_speakers
            ) counts
            ORDER BY relname;
            """
        let output = try run(paths.psql, hostArgs(paths, username: username) + [
            "--dbname", database,
            "--tuples-only",
            "--no-align",
            "--command", sql,
        ])
        var counts: [String: Int] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            counts[String(parts[0].trimmingCharacters(in: .whitespaces))] = value
        }
        return counts
    }

    public static func verifyRestore(
        dumpURL: URL,
        paths: Paths,
        scratchDatabase: String = scratchDatabase,
        run: (String, [String]) throws -> String = runProcess
    ) throws -> [String: Int] {
        let before = try relationCounts(database: database, paths: paths, username: adminRole, run: run)
        try restoreScratch(from: dumpURL, paths: paths, scratchDatabase: scratchDatabase, run: run)
        let after = try relationCounts(database: scratchDatabase, paths: paths, username: adminRole, run: run)
        for (table, count) in before {
            let restored = after[table] ?? -1
            if restored != count {
                throw PostgresBackupError.restoreMismatch(
                    "\(table): live \(count) vs restored \(restored)"
                )
            }
        }
        return after
    }

    public static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw PostgresBackupError.commandFailed(errorText.isEmpty ? output : errorText)
        }
        return output
        #else
        throw PostgresBackupError.commandFailed("pg_dump is Mac-only")
        #endif
    }

    private static func hostArgs(_ paths: Paths, username: String = role) -> [String] {
        ["--host", paths.socketDirectory, "--port", String(port), "--username", username]
    }

    private static func defaultPrefixes() -> [String] {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let environmentPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
            !environmentPrefix.isEmpty
        {
            prefixes.append(environmentPrefix)
        }
        return prefixes
    }
}
