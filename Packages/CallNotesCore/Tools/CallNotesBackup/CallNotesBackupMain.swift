import CallNotesCore
import Darwin
import Foundation

@main
struct CallNotesBackup {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            guard let paths = PostgresBackup.dedicatedPaths() else {
                throw PostgresBackupError.dedicatedInstanceNotFound
            }
            let output = options.output ?? defaultOutputURL()
            _ = try PostgresBackup.backup(
                to: output,
                paths: paths,
                verify: options.verify,
                keepScratch: options.keepScratch
            )
            print(options.verify ? "Backup verified: \(output.path)" : "Backup written: \(output.path)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func defaultOutputURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CallNotes/backups", isDirectory: true)
            .appendingPathComponent("callnotes-\(stamp).dump")
    }

    private struct Options {
        var verify = false
        var keepScratch = false
        var output: URL?

        init(arguments: [String]) throws {
            for argument in arguments {
                switch argument {
                case "--verify":
                    verify = true
                case "--keep-scratch":
                    keepScratch = true
                case "-h", "--help":
                    print("usage: CallNotesBackup [--verify] [--keep-scratch] [--output=PATH]")
                    exit(0)
                default:
                    guard argument.hasPrefix("--output="), argument.count > "--output=".count else {
                        throw UsageError.invalidArgument(argument)
                    }
                    output = URL(fileURLWithPath: String(argument.dropFirst("--output=".count)))
                }
            }
        }
    }

    private enum UsageError: LocalizedError {
        case invalidArgument(String)

        var errorDescription: String? {
            switch self {
            case let .invalidArgument(argument):
                "Invalid argument: \(argument). Usage: CallNotesBackup [--verify] [--keep-scratch] [--output=PATH]"
            }
        }
    }
}
