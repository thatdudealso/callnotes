import Foundation
import Testing

@testable import CallNotesCore

@Suite struct ConsentAnnouncementTests {
    @Test func tonePolicyProducesAudiblePCM() throws {
        let pcm = try #require(ConsentAnnouncement.injection(for: .tone))
        #expect(pcm.count == ConsentAnnouncement.toneSampleRate)
        let rms = sqrt(pcm.reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(pcm.count))
        #expect(rms > AudioConstants.silenceRMSThreshold)
        #expect(ConsentPolicy.spokenLine == "This call is being recorded.")
    }

    @Test func verbalAndOffDoNotInject() {
        #expect(ConsentAnnouncement.injection(for: .announce) == nil)
        #expect(ConsentAnnouncement.injection(for: .off) == nil)
        #expect(!ConsentPolicy.announce.injectsAnnouncement)
        #expect(ConsentPolicy.tone.injectsAnnouncement)
    }

    @Test func mixingToneIntoWriterPutsEnergyOnNearChannel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-consent-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let tone = ConsentAnnouncement.tonePCM()
        let silence = [Int16](repeating: 0, count: tone.count)
        let writer = try StereoCAFWriter(url: url, sampleRate: Double(ConsentAnnouncement.toneSampleRate))
        try writer.write(near: tone, far: silence)
        writer.close()
        let channels = try StereoCAFReader.read(url)
        let nearRMS = sqrt(
            channels.near.reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(channels.near.count)
        )
        let farRMS = sqrt(
            channels.far.reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(channels.far.count)
        )
        #expect(nearRMS > AudioConstants.silenceRMSThreshold)
        #expect(farRMS < AudioConstants.silenceRMSThreshold)
    }

    @Test func mixConsumesInjectionAcrossBuffers() {
        let tone: [Int16] = [100, 200, 300, 400]
        var first = [Int16](repeating: 10, count: 2)
        var consumed = 0
        ConsentAnnouncement.mix(tone, into: &first, consumed: &consumed)
        #expect(first == [110, 210])
        #expect(consumed == 2)
        var second = [Int16](repeating: 5, count: 3)
        ConsentAnnouncement.mix(tone, into: &second, consumed: &consumed)
        #expect(second == [305, 405, 5])
        #expect(consumed == 4)
    }
}
