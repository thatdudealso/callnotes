//
//  TranscriptTidierTests.swift
//  CallNotesCoreTests
//
//  Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone),
//  MIT License:
//    Copyright (c) 2026 Kuber Mehta (Megaphone)
//    Copyright (c) 2026 Zach Latta (FreeFlow)
//  See THIRD_PARTY.md. Adapted for CallNotes: ported the custom assertion
//  harness to Swift Testing and rebranded the fixture vocabulary.
//

import Testing

@testable import CallNotesCore

@Suite struct TranscriptTidierTests {
    @Test func fillers() {
        expectCases([
            ("Um I think we should ship it.", "I think we should ship it."),
            ("I, uh, think this works", "I think this works"),
            ("I—uh—think this works", "I think this works"),
            ("uh uhm erm", ""),
            ("UH, hello", "hello"),
            ("That was yummy and the umbra moved.", "That was yummy and the umbra moved."),
        ])
    }

    @Test func safeRepeatedWordsAndStutters() {
        expectCases([
            ("I I think the the build works", "I think the build works"),
            ("we we we should go", "we should go"),
            ("th- the release is ready", "the release is ready"),
            ("I w- want this", "I want this"),
        ])
    }

    @Test func meaningfulSpeechIsPreserved() {
        let unchanged = [
            "This is very very important.",
            "I like the first design.",
            "Use uh_value and umbraColor.",
            "Visit https://example.com/a--b.",
            "हाँ यह बहुत बहुत ज़रूरी है।",
            "The go-go release is intentional.",
        ]
        for input in unchanged {
            #expect(TranscriptTidier.tidy(input) == input)
        }
    }

    @Test func whitespaceAndPunctuation() {
        expectCases([
            ("  hello   world  ", "hello world"),
            ("hello , world !", "hello, world!"),
            ("um, hello", "hello"),
            ("hello, uh", "hello"),
        ])
    }

    @Test func correctionParsing() {
        let parsed = TranscriptTidier.CorrectionMapping.parse(
            """
            # Personal vocabulary
            call notes -> CallNotes
            jason => JSON
            floo id audio → FluidAudio
            bad line
             -> missing
            CALL NOTES -> duplicate
            too -> many -> arrows
            """)
        #expect(
            parsed == [
                .init(spoken: "call notes", replacement: "CallNotes"),
                .init(spoken: "jason", replacement: "JSON"),
                .init(spoken: "floo id audio", replacement: "FluidAudio"),
            ])
    }

    @Test func correctionApplication() {
        let mappings = TranscriptTidier.CorrectionMapping.parse(
            """
            call notes -> CallNotes
            jason -> JSON
            see plus plus -> C++
            """)
        #expect(
            TranscriptTidier.tidy("Use call   notes with jason and see plus plus.", corrections: mappings)
                == "Use CallNotes with JSON and C++.")
        #expect(
            TranscriptTidier.tidy("The callnotes app uses jsonValue.", corrections: mappings)
                == "The callnotes app uses jsonValue.")
    }

    @Test func replacementTextIsNotProcessedAgain() {
        let mappings = TranscriptTidier.CorrectionMapping.parse(
            """
            visual studio code -> VS Code
            code -> CODE
            """)
        #expect(TranscriptTidier.tidy("Open visual studio code.", corrections: mappings) == "Open VS Code.")
    }

    @Test func idempotence() {
        let inputs = [
            "Um I I think, uh, th- the build works.",
            "This is very very important.",
            "hello , world !",
        ]
        for input in inputs {
            let once = TranscriptTidier.tidy(input)
            #expect(TranscriptTidier.tidy(once) == once)
        }
    }

    private func expectCases(_ cases: [(String, String)]) {
        for (input, expected) in cases {
            #expect(TranscriptTidier.tidy(input) == expected, "input: \(input)")
        }
    }
}
