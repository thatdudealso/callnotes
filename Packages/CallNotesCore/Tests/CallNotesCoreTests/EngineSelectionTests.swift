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

    @Test func importPrefersParakeetWhenItsModelsAreUsable() {
        #expect(
            EngineSelection.resolveImport(
                configuredDefault: .appleSpeech,
                metaIsConfigured: false,
                parakeetIsUsable: true
            ) == .fluidParakeet)
    }

    @Test func importFallsBackToAppleWithoutParakeetModels() {
        #expect(
            EngineSelection.resolveImport(
                configuredDefault: .appleSpeech,
                metaIsConfigured: false,
                parakeetIsUsable: false
            ) == .appleSpeech)
    }

    @Test func unconfiguredMetaImportStillPrefersParakeet() {
        #expect(
            EngineSelection.resolveImport(
                configuredDefault: .metaMuse,
                metaIsConfigured: false,
                parakeetIsUsable: true
            ) == .fluidParakeet)
    }

    @Test func configuredMetaImportStaysOnMeta() {
        #expect(
            EngineSelection.resolveImport(
                configuredDefault: .metaMuse,
                metaIsConfigured: true,
                parakeetIsUsable: true
            ) == .metaMuse)
    }

    @Test func shipsWithLocalDefault() {
        #expect(EngineSelection.resolve(override: nil, configuredDefault: nil) == .appleSpeech)
    }
}
