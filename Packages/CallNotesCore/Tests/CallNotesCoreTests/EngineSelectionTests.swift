import Testing

@testable import CallNotesCore

@Suite struct EngineSelectionTests {
    @Test func perCallOverrideWins() {
        #expect(
            EngineSelection.resolve(override: .metaMuse, configuredDefault: .appleSpeech)
                == .metaMuse)
    }

    @Test func configuredDefaultUsedWithoutOverride() {
        #expect(
            EngineSelection.resolve(override: nil, configuredDefault: .metaMuse) == .metaMuse)
    }

    @Test func shipsWithLocalDefault() {
        #expect(EngineSelection.resolve(override: nil, configuredDefault: nil) == .appleSpeech)
    }
}
