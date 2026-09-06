# CallNotes brand

CallNotes ships with its own identity. Interaction patterns borrowed from
Megaphone (wizard card flow, permission cards, live pill) are re-skinned to
this design language; no Megaphone name, icon, asset, or user-visible string
ships in any surface. A release gate greps the product for Megaphone-branded
identifiers and strings.

## Naming

- Product name: **CallNotes** (one word, capital C and N).
- Bundle ids: `com.thatdudealso.callnotes` (Mac), `com.thatdudealso.callnotes.ios` (iPhone), `com.thatdudealso.callnotes.ios.ShareExtension`.
- App Group (Phase 6): `group.com.thatdudealso.callnotes`.
- Log subsystem: `com.thatdudealso.callnotes`.
- Bonjour service: `_callnotes._tcp`.

## Placeholder visual identity (Phase 0)

Final art comes later; until then:

- Icon: SF Symbol `phone.badge.waveform` on a deep-teal rounded rectangle.
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
