# Raw upstream locale digests (test fixtures)

These vendor the upstream web client's localized card image digest *data*
byte-identical to the exact pinned upstream commit (see below) — not merely
unchanged in content, but never reformatted, re-serialized, or otherwise
transformed from the upstream bytes in any way. They are **not** production
data (production uses the compact resources under
`Sources/ArkhamHorrorShared/Resources/AssetDigests/`, generated *from* these
raw fixtures) and contain no image bytes — only relative filename strings
that already ship in the web client's public JavaScript bundle.

- Source repository: `djensenius/ArkhamHorror`, pinned commit
  `6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27`.
- Source files: `frontend/src/digests/{ita,fr,es,ko,zh}.json`, vendored here
  as `{it,fr,es,ko,zh}.json` (bytes unchanged; only the filename's locale
  prefix is normalized to match this package's own locale-identifier
  convention).

`Scripts/verify-locale-digest-provenance.sh` (`mise run
locale-digest-provenance`) enforces this byte-identical contract directly
against the real upstream repository at the pinned commit — see
`Sources/ArkhamHorrorShared/Resources/AssetDigests/PROVENANCE.md` for the
full verification pipeline, and the *compaction* transformation these raw
fixtures are the (unchanged) input to.
