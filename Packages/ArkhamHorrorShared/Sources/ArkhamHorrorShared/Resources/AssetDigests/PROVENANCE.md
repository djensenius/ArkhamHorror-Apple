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

## Provenance verification

The raw (pre-compaction) fixtures vendored at
`Tests/ArkhamHorrorSharedTests/Fixtures/LocaleDigests/raw/` are governed by two
independent, layered checks, mirroring the existing pattern for the backend
contract fixtures (`Sources/ArkhamHorrorShared/Domain/Contract/ContractFixtureDigest.swift`
/ `Scripts/verify-contract-fixture-provenance.sh`):

1. **Offline, in-repository self-consistency** — `LocaleDigestFixtureDigests`
   (`Sources/ArkhamHorrorShared/Domain/Asset/LocaleDigestFixtureProvenance.swift`)
   pins a SHA-256 digest and the exact upstream path for each vendored raw
   fixture; `LocaleDigestFixtureProvenanceTests` recomputes each digest from the
   bundled bytes and fails if either drifts. This alone proves the vendored
   bytes match what this repository itself last recorded, but not that they
   still match the real upstream repository.
2. **Network-dependent, upstream-authoritative** — `mise run
   locale-digest-provenance` (`Scripts/verify-locale-digest-provenance.sh`)
   fetches the exact pinned commit above from the real
   `https://github.com/djensenius/ArkhamHorror.git` and byte-compares (and
   git-mode-verifies) every vendored raw fixture against it directly. This is
   excluded from the offline test suite (it requires network access) but its
   own logic is exercised fully offline by `mise run
   locale-digest-provenance-selftest`
   (`Scripts/test-verify-locale-digest-provenance.sh`) against disposable
   scratch git repositories.

Confirmed upstream git blob hashes at the pinned commit (matching
`git hash-object`/`git ls-tree`, independent of this package's own SHA-256
digests above):

| Local file | Upstream path                     | Git blob SHA-1                            |
|------------|------------------------------------|--------------------------------------------|
| `it.json`  | `frontend/src/digests/ita.json`   | `c5a00c024df57faef625534846b4b15dd47031ce` |
| `fr.json`  | `frontend/src/digests/fr.json`    | `ae51a407f1c8a261cc20c6bc475e667b03358111` |
| `es.json`  | `frontend/src/digests/es.json`    | `819fa0618db920bf6ca14bfe597a0c815ad009aa` |
| `ko.json`  | `frontend/src/digests/ko.json`    | `0637a088a01e8ddab3bf3fa98dbe804cbde1a0dc` |
| `zh.json`  | `frontend/src/digests/zh.json`    | `1e475a20c1cd3dd1290d2cec8f4eed0ca0e329aa` |

All five are mode `100644` (regular file, never a symlink/executable/gitlink)
at the pinned commit.

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
