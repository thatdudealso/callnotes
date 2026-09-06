//
//  DictionaryStoreTests.swift
//  CallNotesCoreTests
//
//  Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone),
//  MIT License:
//    Copyright (c) 2026 Kuber Mehta (Megaphone)
//    Copyright (c) 2026 Zach Latta (FreeFlow)
//  See THIRD_PARTY.md. Adapted for CallNotes: ported the custom assertion
//  harness to Swift Testing, rebranded fixture vocabulary, dropped the
//  Megaphone legacy-preference migration tests (feature not vendored), and
//  renamed the export version key.
//

import Foundation
import Testing

@testable import CallNotesCore

@Suite(.serialized) struct DictionaryStoreTests {
    private func makeStore() -> (DictionaryStore, UserDefaults, String) {
        let suite = "DictionaryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (DictionaryStore(defaults: defaults, storageKey: "entries"), defaults, suite)
    }

    @Test func manualTermsAndProjection() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = try store.addManual("  CallNotes  ")
        _ = try store.addManual("SpeechAnalyzer")
        #expect(store.activeTerms == ["CallNotes", "SpeechAnalyzer"])
        store.setEnabled(false, for: first.id)
        #expect(store.activeTermsText == "SpeechAnalyzer")
        #expect(throws: DictionaryStoreError.duplicateTerm) { try store.addManual("callnotes") }
        #expect(throws: DictionaryStoreError.emptyTerm) { try store.addManual("   ") }
    }

    @Test func conservativeLearning() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.observe(candidateTerms: ["Priya", "Priya"])
        #expect(store.entries.first?.observationCount == 1)
        #expect(store.entries.first?.status == .suggested)
        #expect(store.activeTerms.isEmpty, "A one-off suggestion became active")
        store.observe(candidateTerms: ["priya"])
        #expect(store.entries.first?.observationCount == 2)
        store.observe(candidateTerms: ["Priya"])
        #expect(store.entries.first?.status == .active)
        #expect(store.activeTerms == ["Priya"])
    }

    @Test func manualEntryPromotesSuggestion() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.observe(candidateTerms: ["Obsidian"])
        let entry = try store.addManual("Obsidian")
        #expect(entry.source == .manual)
        #expect(entry.status == .active)
        #expect(store.entries.count == 1)
    }

    @Test func automaticLearningToggle() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.automaticLearningEnabled = false
        store.observe(candidateTerms: ["Cursor"])
        #expect(store.entries.isEmpty, "Learning toggle was ignored")

        let reloaded = DictionaryStore(defaults: defaults, storageKey: "entries")
        #expect(!reloaded.automaticLearningEnabled, "Learning toggle was not persisted")
    }

    @Test func persistence() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try store.addManual("Foundation Models")
        let reloaded = DictionaryStore(defaults: defaults, storageKey: "entries")
        #expect(reloaded.activeTerms == ["Foundation Models"])
    }

    @Test func conservativeCandidateExtraction() {
        let candidates = DictionaryTermLearner.candidates(
            from: "Please send this to Priya and keep SpeechAnalyzer, GPT-5, and JSON intact."
        )
        #expect(candidates.contains("Priya"), "Missed a mid-sentence name")
        #expect(candidates.contains("SpeechAnalyzer"), "Missed an internal-cap technical term")
        #expect(candidates.contains("GPT-5"), "Missed a versioned technical term")
        #expect(candidates.contains("JSON"), "Missed an acronym")
        #expect(!candidates.contains("Please"), "Learned sentence-initial capitalization")
        #expect(!candidates.contains("send"), "Learned an ordinary word")
    }

    @Test func dismissedSuggestionStaysDismissed() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.observe(candidateTerms: ["Priya"])
        let entry = store.entries[0]
        store.dismissSuggestion(id: entry.id)
        store.observe(candidateTerms: ["Priya"])
        #expect(store.entries[0].status == .rejected)
        #expect(store.entries[0].observationCount == 1)
        let restored = try store.addManual("Priya")
        #expect(restored.status == .active)
        #expect(restored.source == .manual)
    }

    @Test func decodesEntriesStoredBeforeRanking() {
        let suite = "DictionaryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A stored blob from before `starred`/`usageCount` existed.
        let legacyBlob = """
            [{"id":"1B8F4E2A-6C1D-4E5B-9A3F-2D7C8E0B4A61","term":"CallNotes","source":"manual",\
            "status":"active","isEnabled":true,"observationCount":0,"createdAt":776000000,"updatedAt":776000000}]
            """
        defaults.set(Data(legacyBlob.utf8), forKey: "entries")
        let store = DictionaryStore(defaults: defaults, storageKey: "entries")
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.term == "CallNotes")
        #expect(store.entries.first?.starred == false)
        #expect(store.entries.first?.usageCount == 0)
        #expect(store.activeTerms == ["CallNotes"])
    }

    @Test func promptRankingOrder() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = try store.addManual("Obsidian")
        _ = try store.addManual("Priya")
        let starredEntry = try store.addManual("Zig")
        _ = try store.addManual("Apple")
        store.setStarred(true, for: starredEntry.id)
        store.recordUsage(in: "Ship the Priya build")
        store.recordUsage(in: "Ping Priya about Obsidian")

        // Starred beats usage, usage beats alphabetical, alphabetical breaks ties.
        #expect(store.activeTerms == ["Zig", "Priya", "Obsidian", "Apple"])
    }

    @Test func usageMatchingRespectsWordBoundaries() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = try store.addManual("AI")
        store.recordUsage(in: "We maintain the daily chain")
        #expect(store.entries.first?.usageCount == 0)
        store.recordUsage(in: "The AI pipeline, obviously.")
        #expect(store.entries.first?.usageCount == 1)
        // Punctuation is a boundary; repeats within one transcript count once.
        store.recordUsage(in: "ai, ai everywhere")
        #expect(store.entries.first?.usageCount == 2)
        #expect(
            DictionaryStore.containsWholeWord("Foundation Models", in: "use Foundation Models."),
            "Missed a multi-word phrase")
        #expect(
            !DictionaryStore.containsWholeWord("Foundation Models", in: "foundation modelscope"),
            "Matched inside a longer word")
    }

    @Test func usageIncrementsOnlyEnabledEntries() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = try store.addManual("SpeechAnalyzer")
        let disabled = try store.addManual("Obsidian")
        store.setEnabled(false, for: disabled.id)
        store.observe(candidateTerms: ["Claurst"])  // suggested, not active
        store.recordUsage(in: "SpeechAnalyzer feeds Obsidian and Claurst")
        #expect(store.entries.first { $0.term == "SpeechAnalyzer" }?.usageCount == 1)
        #expect(store.entries.first { $0.term == "Obsidian" }?.usageCount == 0)
        #expect(store.entries.first { $0.term == "Claurst" }?.usageCount == 0)
    }

    @Test func starAndUsagePersist() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = try store.addManual("CallNotes")
        store.setStarred(true, for: entry.id)
        store.recordUsage(in: "CallNotes shipped")
        let reloaded = DictionaryStore(defaults: defaults, storageKey: "entries")
        #expect(reloaded.entries.first?.starred == true)
        #expect(reloaded.entries.first?.usageCount == 1)
    }

    @Test func exportDocumentRoundTrip() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let starred = try store.addManual("CallNotes")
        store.setStarred(true, for: starred.id)
        store.observe(candidateTerms: ["Priya"])

        let document = store.exportDocument(exactCorrections: "call notes → CallNotes")
        let decoded = try DictionaryExportDocument.decode(document.encoded())

        #expect(decoded.callnotesDictionaryVersion == DictionaryExportDocument.currentVersion)
        #expect(decoded.exactCorrections == "call notes → CallNotes")
        // ISO-8601 drops sub-second precision, so compare everything but dates.
        #expect(decoded.entries.map(\.term) == store.entries.map(\.term))
        #expect(decoded.entries.map(\.source) == store.entries.map(\.source))
        #expect(decoded.entries.map(\.status) == store.entries.map(\.status))
        #expect(decoded.entries.map(\.starred) == store.entries.map(\.starred))
        #expect(decoded.entries.map(\.isEnabled) == store.entries.map(\.isEnabled))
        #expect(decoded.entries.map(\.observationCount) == store.entries.map(\.observationCount))
    }

    @Test func importMergesByTerm() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = try store.addManual("CallNotes")
        store.observe(candidateTerms: ["Priya"])  // local suggestion
        store.observe(candidateTerms: ["Cursor"])
        store.dismissSuggestion(id: store.entries.first { $0.term == "Cursor" }!.id)
        store.observe(candidateTerms: ["Claurst"])
        store.dismissSuggestion(id: store.entries.first { $0.term == "Claurst" }!.id)

        let imported = [
            // Duplicate of a local active entry: stars and usage merge in.
            DictionaryEntry(term: "callnotes", source: .manual, status: .active, starred: true, usageCount: 9),
            // Explicitly taught on the other Mac: activates the local suggestion.
            DictionaryEntry(term: "Priya", source: .manual, status: .active),
            // A mere suggestion elsewhere must not resurrect a local rejection.
            DictionaryEntry(term: "Cursor", source: .learned, status: .suggested),
            // But an explicit activation elsewhere wins over a local rejection.
            DictionaryEntry(term: "claurst", source: .manual, status: .active),
            // Brand new term.
            DictionaryEntry(term: "SpeechAnalyzer", source: .manual, status: .active),
            DictionaryEntry(term: "   ", source: .manual, status: .active),
        ]
        let result = store.importEntries(imported)

        #expect(result.addedCount == 1)
        #expect(result.updatedCount == 3)
        let callnotes = store.entries.first { $0.term == "CallNotes" }!
        #expect(callnotes.starred == true)
        #expect(callnotes.usageCount == 9)
        #expect(store.entries.first { $0.term == "Priya" }?.status == .active)
        #expect(store.entries.first { $0.term == "Cursor" }?.status == .rejected)
        let claurst = store.entries.first { $0.term == "Claurst" }!
        #expect(claurst.status == .active)
        #expect(claurst.source == .manual)
        #expect(claurst.isEnabled, "Reactivated entry should be enabled")
        #expect(store.entries.first { $0.term == "SpeechAnalyzer" }?.status == .active)
        #expect(store.entries.count == 5)
    }

    @Test func importPersists() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.importEntries([
            DictionaryEntry(term: "Obsidian", source: .manual, status: .active, starred: true, usageCount: 4)
        ])
        let reloaded = DictionaryStore(defaults: defaults, storageKey: "entries")
        #expect(reloaded.activeTerms == ["Obsidian"])
        #expect(reloaded.entries.first?.starred == true)
        #expect(reloaded.entries.first?.usageCount == 4)
    }

    @Test func mergedCorrections() {
        let merged = DictionaryStore.mergedCorrections(
            local: "call notes → CallNotes\n",
            imported: "CALL NOTES → CallNotes\npriya → Priya\n\npriya → Priya"
        )
        #expect(merged.text == "call notes → CallNotes\npriya → Priya")
        #expect(merged.addedCount == 1)

        let fromEmpty = DictionaryStore.mergedCorrections(local: "", imported: "a → b")
        #expect(fromEmpty.text == "a → b")
        #expect(fromEmpty.addedCount == 1)

        let nothingNew = DictionaryStore.mergedCorrections(local: "a → b", imported: "a → b\n")
        #expect(nothingNew.text == "a → b")
        #expect(nothingNew.addedCount == 0)
    }
}
