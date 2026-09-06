import Foundation
import Testing

@testable import CallNotesCore

@Suite struct PCMResamplerTests {
    @Test func identityRatePreservesSamples() {
        let input: [Float] = [0, 0.25, 0.5, 0.75]
        let output = PCMResampler.resampleMono(input: input, inputSampleRate: 16_000, outputSampleRate: 16_000)
        #expect(output == input)
    }

    @Test func downsample48kTo16kShortensByThree() {
        let input = (0..<300).map { Float($0) }
        let output = PCMResampler.resampleMono(input: input, inputSampleRate: 48_000, outputSampleRate: 16_000)
        #expect(output.count == 100)
        #expect(abs(output[0] - 0) < 0.01)
        #expect(abs(output[1] - 3) < 0.01)
    }

    @Test func sineEnergySurvivesResampleAndInt16Conversion() {
        let rateIn = 48_000.0
        let seconds = 0.25
        let frequency = 440.0
        let count = Int(rateIn * seconds)
        let input: [Float] = (0..<count).map { i in
            sin(2 * Double.pi * frequency * Double(i) / rateIn)
        }.map { Float($0) }
        let int16 = PCMResampler.resampleMonoToInt16(input: input, inputSampleRate: rateIn)
        #expect(int16.count == Int(16_000 * seconds))
        let rms = sqrt(int16.reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(int16.count))
        #expect(rms > 5_000)
    }

    @Test func mixdownAveragesChannels() {
        let interleaved: [Float] = [1, 3, 5, 7]
        let mono = PCMResampler.mixdownMono(interleaved: interleaved, channels: 2)
        #expect(mono == [2, 6])
    }

    @Test func clipToInt16Saturates() {
        #expect(PCMResampler.clipToInt16(2) == Int16.max)
        #expect(PCMResampler.clipToInt16(-2) == -Int16.max)
        #expect(PCMResampler.clipToInt16(0) == 0)
    }
}