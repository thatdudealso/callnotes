# CallNotes brand

CallNotes ships with its own identity. Interaction patterns borrowed from
Megaphone (wizard card flow, permission cards, live pill) are re-skinned to
this design language; no Megaphone name, icon, asset, or user-visible string
ships in any surface. A release gate greps the product for Megaphone-branded
identifiers and strings.

## Naming

- Product name: **CallNotes** (one word, capital C and N).
- Bundle ids: `com.thatdudealso.callnotes` (Mac), `com.thatdudealso.callnotes.ios` (iPhone), `com.thatdudealso.callnotes.ios.ShareExtension`.
- App Group (Phase 6): `group.com.thatdudealso.callnotes`, shared by the iPhone app and its Share Extension.
- Keychain access group (Phase 6): `$(AppIdentifierPrefix)group.com.thatdudealso.callnotes`; the team prefix is resolved at runtime, never hardcoded.
- Log subsystem: `com.thatdudealso.callnotes`.
- Bonjour service: `_callnotes._tcp`.

## Visual identity

- Icon: original **diary-facing-voices** mark - a closed cream diary on teal
  with spine and page edges, and two facing voice-prints on the cover (two
  heavy rings each, asymmetric spacing so they read as two people talking).
  The menu bar uses the same mark: idle is outline, armed is filled,
  recording layers a red dot, processing layers a spinner.
  Mac and iPhone share the catalog in `Resources/Assets.xcassets`.
  `Scripts/render-app-icon-concepts.swift` is the raster source.
- Accent palette:
  - Primary: deep teal `#0E7C7B`
  - Recording red: `#D64545`
  - Cloud (Meta engine) indicator: slate blue `#5B7DB1`
  - Neutral text: system label colors (respect light/dark).
- Typography: system fonts (SF Pro / SF Compact); no custom faces.

## Copy voice

- Plain, calm, and specific. No exclamation marks in system UI.
- Privacy claims are literal: "Audio never leaves this Mac unless you enable
  the cloud engine." Only say it where it is true.
- Recording status is always visible while recording; never euphemize
  ("recording", not "listening").
