import CallNotesCore
import Darwin
import Foundation

/// Writes a stereo CAF incrementally until it is killed.
@main
struct CAFCrashWriter {
    static func main() throws {
        precondition(CommandLine.arguments.count >= 2, "usage: CAFCrashWriter <caf-url> [frames]")
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let frames = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8_000) : 8_000
        let writer = try StereoCAFWriter(url: url, sampleRate: 16_000)
        let batchSize = min(256, frames)
        var written = 0
        var announced = false
        while written < frames {
            let end = min(written + batchSize, frames)
            let near = (written..<end).map { Int16($0 % 1000) }
            let far = (written..<end).map { Int16(-($0 % 1000)) }
            try writer.write(near: near, far: far)
            try writer.persistPacketCount()
            written = end
            if !announced {
                FileHandle.standardOutput.write(Data("ready\n".utf8))
                fflush(stdout)
                announced = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        while true {
            Thread.sleep(forTimeInterval: 60)
        }
    }
}
