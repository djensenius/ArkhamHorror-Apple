# Localized digest provenance

These files are **generated data**, not handwritten source. Each `<locale>.json`
is a sorted, deduplicated JSON array of card identifiers (e.g. `"01001"`,
`"04105_Mutated21"`) that have a localized image available on the hosted asset
CDN for that locale.

## Source

- Upstream repository: `djensenius/ArkhamHorror` (web client, a fork of
  `halogenandtoast/ArkhamHorror`).
- Pinned commit: `6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27`.
- Source files: `frontend/src/digests/{ita,fr,es,ko,zh}.json`.
- No image bytes are vendored — only filename lists that already ship in the
  web client's public bundle.

## Transformation

Each compact file was produced by keeping only entries with a `cards/` prefix
from the corresponding raw upstream digest, stripping that prefix and the file
extension, discarding entries that do not match the card-code grammar
(`AssetIdentifier.cardCode`), then sorting and deduplicating the remainder.
Entries with any other prefix (e.g. `tarot/`) or a malformed code are dropped;
this is intentional and fails closed (that entry is simply never treated as
localized, matching the safe default of falling back to the English asset).
The same pure transformation is re-applied in
`LocalizedDigestCompactorDriftTests` against the raw upstream files vendored at
`Tests/ArkhamHorrorSharedTests/Fixtures/LocaleDigests/raw/` to detect drift
between the shipped compact resource and the pinned upstream source.

## Web locale → path root mapping

| Locale code | Web root folder |
|-------------|------------------|
| `it`        | `ita`            |
| `fr`        | `fr`             |
| `es`        | `es`             |
| `ko`        | `ko`             |
| `zh`        | `zh`             |

`ko.json` is currently empty upstream (no localized Korean card images are
published yet), so every Korean-locale request falls back to English. This
mirrors production behavior exactly rather than special-casing it.
