# Test Fixtures

## Contract fixtures

Vendored byte-for-byte from:
`djensenius/ArkhamHorror@39b580ff5e28a091acaf78aa2a0ed5ec29b1435b`,
schema revision `0.1.30`. Local validation can use the exact backend worktree as
`PROVENANCE_BACKEND_REPO_URL` and `LOCALE_CATALOG_BACKEND_REPO_URL`.

These thirty-three files, and only these thirty-three, live under `Fixtures/Contract/` — a
dedicated subdirectory `ContractFixtureDigestTests` enumerates directly (via
`Bundle.module.urls(forResourcesWithExtension:subdirectory:)`), so adding, removing, or
substituting a file there is caught by comparing the directory's actual contents against
`ContractFixtureDigests.all`, not by maintaining a second hardcoded list. The full backend
contract manifest references many additional schema documents (OpenAPI, AsyncAPI, JSON
Schemas) that are **not** reproduced. The basic-choice schema is vendored here to bind
the encounter draw's semantic label and closed nested shape to the same immutable pin.
See the backend repository for the remaining authoritative contract documents.

`ContractFixtureDigests.all` binds each file's SHA-256 digest to
`ContractPin.current.backendCommit`; `ContractFixtureDigestTests` recomputes and compares
them so that changing a vendored file's bytes, or bumping the pin without re-vendoring,
fails a test. `catalog.json`, `decks.json`, and `game-lifecycle.json` are hand-assembled
fixture *containers* combining several independent endpoints' shapes for test convenience;
production models decode their individual sub-shapes directly (`CardDef`,
`DeckListInput`/`DeckList`/`Deck`, `CreateGameRequest`, etc.), not the container itself.
`game-list.json` and `capabilities.json` each match a single production response shape
directly. `get-game.json` and `game-update.json` are the exact, non-empty production
REST/WebSocket envelopes both decoding to the same `PublicGameSnapshot`
(`get-game.json`'s `game` field is byte-identical to `game-update.json`'s `contents`
field). `mode-turn-zero.json`, `mode-campaign-only.json`, `mode-campaign-scenario.json`,
`location-enemy-view.json`, `movement.json`, `act-no-advance-cost.json`,
`investigator-unhealed-horror-negative.json`, `uuid-entity-map.json`, and
`card-code-entity-map.json`, `question-choose-one.json`,
`question-player-window-choose-one.json`, `question-window-choose-one.json`, and
`answer-question.json` are focused, sub-shape fixtures exercising specific governed
branches (`Data.These` mode sibling-key combinations and turn zero, the disjoint enemy
location view, an in-progress `Movement`, an act with no `advanceCost`, negative
``unhealedHorrorThisRound`, the UUID-/`CardCode`-keyed entity map shapes, and the basic
choice question/answer shapes) that are not
otherwise exercised by the single non-empty `get-game.json`/`game-update.json` fixture.

`question-read.json` and `question-read-with-cards.json` are the production
`setupTheGathering` opening `Read`/`BasicReadChoices` continue prompt (`readCards: null`
and its sibling non-null `readCards` branch); `question-choose-one-location.json` and
`question-choose-one-location-multiple.json` are the `startAt` starting-location
`ChooseOne`/`TargetLabel(LocationTarget)` prompt with, respectively, the single real
"Study" starting location and three real "The Gathering" locations proving backend choice
order and zero-based `Answer.choice` index stability. `question-mulligan.json` is the
production opening-hand `ChooseOne` prompt with its localized done action at source index
zero and three `TargetLabel(CardIdTarget)` choices in authoritative hand order.
`question-investigate-fast-window.json`, `question-investigate-commit.json`,
`question-investigate-reveal-window.json`, and `question-investigate-apply-results.json`
are the production basic-investigation prompt sequence, preserving the backend's exact
card/control source indices through both fast windows, card commitment, test start, and
result application.

`question-encounter-deck-draw.json` is the production Mythos `ChooseOne` prompt:
source index zero is `TargetLabel(EncounterDeckTarget)` with one closed `DrawCards`
message. The vendored `basic-choice-question.schema.json` publishes its semantic title,
**Draw encounter card**, under `encounterDeckDrawLabel.title`. The client validates only
this one-card, unresolved, standard, top-of-encounter-deck draw from `GameSource`,
preserves the message bytes as data, and submits the unchanged versioned answer index.
Other draw shapes remain unsupported; no game rules execute on the client.
Fixture-driven tests apply all 47 encounter negatives from the unmodified manifest
in memory, plus client numeric, required-field, source-index, focus, pending, stale,
and reconnect/retry boundaries. Both the digest registry and the backend manifest's
`artifactHashes` bind the vendored fixture and schema bytes.

## token.json / whoami.json

Synthetic, hand-authored fixtures used by the authentication-session tests. They live
directly under `Fixtures/`, deliberately **outside** `Fixtures/Contract/`, since they are
**not** vendored from the backend, are unrelated to the contract pin, and contain **no**
real or reusable credentials:

- `token.json` — a `Token` response whose `token` is the obvious placeholder
  `fixture-token-not-a-real-credential`.
- `whoami.json` — a `CurrentUser` response for a fictional account
  (`investigator@example.com`).
