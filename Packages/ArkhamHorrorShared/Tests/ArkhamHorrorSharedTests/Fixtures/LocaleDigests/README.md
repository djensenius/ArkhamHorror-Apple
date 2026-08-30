# Raw upstream locale digests (test fixtures)

These vendor the upstream web client's localized card image digest *data*
unchanged, reformatted only for deterministic, reviewable diffs. They are
**not** production data (production uses the compact resources under
`Sources/ArkhamHorrorShared/Resources/AssetDigests/`) and contain no image
bytes — only relative filename strings that already ship in the web client's
public JavaScript bundle.

- Source repository: `djensenius/ArkhamHorror`, pinned commit
  `6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27`.
- Source files: `frontend/src/digests/{ita,fr,es,ko,zh}.json`. The set of
  filename strings in each locale is unchanged from upstream; the raw bytes
  differ because each file was re-serialized as one-entry-per-line JSON
  arrays for a stable, reviewable diff (upstream's own minified/compact
  JSON would otherwise render as a single opaque line per file here).

See `Sources/ArkhamHorrorShared/Resources/AssetDigests/PROVENANCE.md` for the
transformation these fixtures are checked against.
