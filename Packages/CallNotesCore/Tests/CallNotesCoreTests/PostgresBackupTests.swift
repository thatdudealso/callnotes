import Foundation
import Testing

@testable import CallNotesCore

@Suite struct PostgresBackupTests {
    @Test func dedicatedPathsIgnoreGenericPostgresSockets() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-pg-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generic = root.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: generic, withIntermediateDirectories: true)
        try? Data().write(to: generic.appendingPathComponent(".s.PGSQL.5432"))
        #expect(
            PostgresBackup.dedicatedPaths(homebrewPrefixes: [root.path], fileManager: .default) == nil
        )
    }

    @Test func verifyRestoreComparesLiveAndScratchCounts() throws {
        var commands: [[String]] = []
        let run: (String, [String]) throws -> String = { executable, arguments in
            commands.append([executable] + arguments)
            if executable.hasSuffix("psql") {
                return "calls=3\nnotes=3\nsegments=10\nspeaker_profiles=2\ncall_speakers=4\n"
            }
            return ""
        }
        let paths = PostgresBackup.Paths(
            socketDirectory: "/opt/homebrew/var/callnotes-postgresql@18/socket",
            binDirectory: "/opt/homebrew/opt/postgresql@18/bin"
        )
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.dump")
        let backup = try PostgresBackup.backup(to: dump, paths: paths, verify: true, run: run)
        let counts = try #require(backup)
        #expect(counts["calls"] == 3)
        #expect(commands.contains { $0.contains(PostgresBackup.scratchDatabase) })
        #expect(commands.allSatisfy { !$0.contains("5432") })
        #expect(commands.allSatisfy { !$0.contains("/tmp/.s.PGSQL.5432") })
        #expect(commands.contains { $0.first?.hasSuffix("pg_restore") == true })
        #expect(commands.contains { cmd in
            cmd.first?.hasSuffix("createdb") == true && cmd.contains(PostgresBackup.adminRole)
        })
        #expect(commands.contains { cmd in
            cmd.first?.hasSuffix("pg_restore") == true && cmd.contains(PostgresBackup.adminRole)
        })
    }
}
