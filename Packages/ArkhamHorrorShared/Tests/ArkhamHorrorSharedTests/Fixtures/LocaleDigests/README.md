# Raw upstream locale digests (test fixtures)

These are unmodified copies of the upstream web client's localized card image
digests, vendored only for deterministic drift testing. They are **not**
production data (production uses the compact resources under
`Sources/ArkhamHorrorShared/Resources/AssetDigests/`) and contain no image
bytes — only relative filename strings that already ship in the web client's
public JavaScript bundle.

- Source repository: `djensenius/ArkhamHorror`, pinned commit
  `6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27`.
- Source files: `frontend/src/digests/{ita,fr,es,ko,zh}.json`, copied verbatim
  and re-serialized as one-entry-per-line JSON arrays (content unchanged).

See `Sources/ArkhamHorrorShared/Resources/AssetDigests/PROVENANCE.md` for the
transformation these fixtures are checked against.
