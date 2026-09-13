import CallNotesCore
import Darwin
import Foundation

/// Writes a stereo CAF, flushes the header, then waits to be killed. Used by
/// `CAFHeaderRepairTests.processKillMidWriteLeavesProcessableCAF`.
@main
struct CAFCrashWriter {
    static func main() throws {
        precondition(CommandLine.arguments.count >= 2, "usage: CAFCrashWriter <caf-url> [frames]")
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let frames = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8_000) : 8_000
        let near = (0..<frames).map { Int16($0 % 1000) }
        let far = (0..<frames).map { Int16(-($0 % 1000)) }
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        try writer.write(near: near, far: far)
        try writer.persistPacketCount()
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        fflush(stdout)
        while true {
            Thread.sleep(forTimeInterval: 60)
        }
    }
}
