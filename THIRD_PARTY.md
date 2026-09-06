# Third-party notices

## Megaphone

CallNotes selectively adapts source from [Megaphone](https://github.com/Kuberwastaken/megaphone), licensed under MIT. The original copyright notices remain in the headers of each adapted source file.

| Candidate component | Phase 0 decision | CallNotes location |
| --- | --- | --- |
| Compatibility launcher | Vendored and rebranded | `CallNotesMac/Launcher/CallNotesLauncher.swift` |
| Setup card flow and permission/TCC guidance | Vendored selectively and rebranded | `CallNotesMac/Sources/Setup/` |
| SpeechAnalyzer wrapper | Vendored and moved into the shared package | `Packages/CallNotesCore/Sources/CallNotesCore/Transcription/SpeechAnalyzerService.swift` |
| Foundation Models cleanup pass | Vendored selectively as an opt-in, transcript-only Apple Foundation Models pass, with deterministic cleanup retained as a fallback | `Packages/CallNotesCore/Sources/CallNotesCore/Notes/FoundationModelsCleanupPass.swift`, `Packages/CallNotesCore/Sources/CallNotesCore/Notes/TranscriptTidier.swift` |
| Custom Dictionary | Vendored and adapted for CallNotes vocabulary | `Packages/CallNotesCore/Sources/CallNotesCore/Transcription/DictionaryStore.swift` |
| Updater | Vendored and rebranded | `CallNotesMac/Sources/UpdateManager.swift` |
| Signed-DMG pipeline | Adapted into standalone scripts | `Scripts/release/` |

The source deliberately excludes the upstream features unrelated to CallNotes,
including keyboard-driven speech capture, text delivery to other applications,
voice wake activation, and application-context adaptation. No Megaphone
branding, assets, bundle identifiers, or user-visible product strings ship in
CallNotes.

```text
MIT License

Copyright (c) 2026 Kuber Mehta (Megaphone)
Copyright (c) 2026 Zach Latta (FreeFlow)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
