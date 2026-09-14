# Test Fixtures

## Contract fixtures

Vendored byte-for-byte from:
`djensenius/ArkhamHorror@38d8b466b635e3c9a18995baccac8b67cb6984cc`,
schema revision `0.1.40`. Local validation can use the exact backend worktree as
`PROVENANCE_BACKEND_REPO_URL` and `LOCALE_CATALOG_BACKEND_REPO_URL`.

These 52 files, and only these 52, live under `Fixtures/Contract/` — a
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

`question-enemy-attack.json` is the production enemy-phase `ChooseOneAtATime` prompt:
its only source-index-zero choice is the exact closed regular attack published by
`chooseOneAtATimeEnemyAttackQuestion`, titled **Resolve enemy attack**. The client checks
the repeated enemy UUID and investigator identities dynamically, retains the original
message as opaque data, and requires both identities in the newest board projection before
submitting `answer-enemy-attack.json`'s unchanged versioned index. All other
`ChooseOneAtATime`, enemy target, attack target/type/source/damage variants, extra choices,
and malformed shapes remain update-required. Fixture-driven tests apply all 86 published
enemy-attack negative mutations in memory and cover stale identity, focus/controller,
pending, replacement, reconnect/manual retry, and uncertain-error behavior.

`question-enemy-attack-damage-assignment.json` is the exact production follow-up from a
Ghoul Minion's one-damage/one-horror regular attack. It is a closed
`QuestionWithSource(EnemyAttackSource) -> QuestionLabel -> ChooseOne` wrapper with source
index zero assigning damage first and source index one assigning horror first. The client
checks every repeated enemy source, investigator component/message/target identity, amount
tuple, strategy, asset matcher, and candidate array before granting either semantic action.
Both identities must still exist in the newest board projection immediately before
submission. The two dedicated answer fixtures preserve source indices `0` and `1` and
question version `6`; all 114 backend-published negative mutations remain update-required.

## Governed assignment continuations

Both remaining-assignment questions and dedicated Answers originate from the immutable
`djensenius/ArkhamHorror#76` merge. The current revision `0.1.40` manifest and
basic-choice schema continue to govern them. Unlike the former replay-derived draft, these
questions are generated through the real backend game engine, registered in the manifest,
schema-validated, and each backed by 16 published single-mutation negatives.

Both continuations retain the governed Ghoul Minion and Roland identities. Choosing damage
first produces the sole source-index-zero `Assign 1 horror`/`HorrorToken` continuation;
choosing horror first produces the symmetric `Assign 1 damage`/`DamageToken` continuation.
Each sends its exact direct amount followed by the production `(0 damage, 0 horror)`
completion message with both accumulated investigator-target arrays populated. Their
Answers preserve source index `0`, player UUID `00000000-0000-0000-0000-000000000001`,
and question version `7`. The 32 assignment-family negatives within the manifest's 569
total mutations now explicitly replace each continuation's required `AnyAsset` matcher
with `AssetWithTitle`; Apple applies those mutations in memory and remains fail-closed.

`ContractFixtureDigestTests` binds the assignment-family artifacts to
`ContractPin.current`, verifies their exact digest registry entries and manifest hashes,
and checks the fixture/schema links, immutable commit, revision, and mutation counts.

## Governed enemy actions

`question-player-window-enemy-actions.json` is the exact production-generated
six-choice action menu added by `djensenius/ArkhamHorror#78`. Fight remains at source
index `4` with ability index `100`; Evade remains at source index `5` with ability index
`101`. Both carry the canonical enemy UUID
`00000000-0000-0000-0000-000000000388`.

The client recognizes only exact `ActionAbility` / `SingleAction` Fight and Evade labels
whose source is exactly `EnemySource` plus a canonical lowercase UUID. It retains every
other ability, window, and message field as opaque contract data, verifies that the enemy
still exists in the newest board projection, and submits the unchanged source index and
authoritative question version. Unknown actions and malformed or alternate source shapes
remain update-required. The backend manifest publishes two focused negative mutations for
this fixture within its 569 total regressions.

`question-player-window-engage-action.json` is the production post-Evade menu added by
`djensenius/ArkhamHorror#81`. The same Ghoul Minion remains available to Fight at source
index `4` and exposes Engage at source index `5` with production ability index `102`.
Engage requires the exact canonical `EnemySource`, retains every opaque ability/window
field, stays actionable only while that enemy remains in the newest projection, and
submits only the unchanged source index plus authoritative question version. Swift never
calculates or mutates engagement state. The backend manifest publishes three focused
Engage negatives for unknown action text, an alternate source constructor, and uppercase
UUID spelling within the manifest's 569 total regressions.

## Governed round transition

The four round-transition fixtures added by `djensenius/ArkhamHorror#83`
preserve the production Q24-Q27 sequence:

- `question-round-end-forced-ability.json` resolves Dissonant Voices through its
  exact card, treachery, forced-ability, and end-of-round window identities;
- `question-agenda-advance.json` advances Agenda 1 through the exact agenda source
  and message;
- `question-agenda-consequence.json` preserves the localized "take two horror"
  and random-discard branches at their original source indices; and
- `question-agenda-horror-assignment.json` assigns exactly two horror to the
  investigator when the horror branch is selected.

Swift independently verifies repeated dynamic source, target, and investigator
identities because JSON Schema cannot express equality between UUID values. It
does not calculate timing, branch outcomes, horror, or discard state. The
backend manifest publishes 55 focused round-transition mutations within its 569
total regressions.

## Governed Roland Banks reaction

`question-roland-defeat-reaction.json` is the exact production Q32
`WindowChooseOne` prompt added by `djensenius/ArkhamHorror#85`. Source index `0`
is Roland Banks's optional reaction to discover one clue at his location after
he defeats an enemy; source index `1` is the exact `SkipTriggersButton`.

The client accepts only the closed Roland `c01001` ability, criteria, limit,
source/requestor, triggering window, and repeated defeated-enemy identities
published by the backend. It requires canonical integer tokens for ability
indices `1` and `100`, keeps both source indices stable, and checks only that
Roland and his current location remain present before submission. Haskell alone
decides whether the reaction is legal and applies the clue movement. The
manifest publishes 60 focused Roland mutations within its 569 total
regressions.

## Governed Cover Up reaction

`question-cover-up-reaction.json` is the exact production Q33
`WindowChooseOne` prompt added by `djensenius/ArkhamHorror#87`. Source index `0`
is Cover Up's optional replacement for discovering one clue; source index `1`
is the exact `SkipTriggersButton`.

The client accepts only the closed Cover Up `c01007` ability, criteria, limit,
matching treachery source/requestor, declared `WouldDiscoverClues` matcher, and
actual location, skill-test, Roland ability-source, and clue-count identities
published by the backend. It retains both source indices, requires every
governed integer token to use its canonical spelling, and permits submission
only while Roland remains at the affected location and the exact Cover Up
treachery remains present with at least one clue. Haskell alone decides whether
the replacement is legal and mutates investigator, location, and treachery clue
counts. The manifest publishes 88 focused Cover Up mutations within its 569
total regressions.

The deterministic fixture hashes to
`8857d15cd056ac0e4d8556676dfc5746c5f9addaa2054d0b35c245610dbf71b9`.
Authenticated replay prompts can have a different digest because location and
skill-test UUIDs are runtime-generated; they remain governed by the same closed
shape and repeated-identity checks.

`replay-attestation.json` and `replay-attestation.schema.json` govern the durable
server authority returned after an authenticated checkpoint import. The production
replay coordinator uses that contract to bind the imported game, player remapping,
checkpoint bytes, backend build identity, and canonical replay envelope before
submitting any native action. `djensenius/ArkhamHorror#79` repairs the fixture's
canonical receipt digest and pins these bytes to immutable merge
`229b89da24546dc6f0a55b2d08ab0f047eb59808`; revision `0.1.40` rebinds that
same validated fixture to the current contract manifest.

## token.json / whoami.json

Synthetic, hand-authored fixtures used by the authentication-session tests. They live
directly under `Fixtures/`, deliberately **outside** `Fixtures/Contract/`, since they are
**not** vendored from the backend, are unrelated to the contract pin, and contain **no**
real or reusable credentials:

- `token.json` — a `Token` response whose `token` is the obvious placeholder
  `fixture-token-not-a-real-credential`.
- `whoami.json` — a `CurrentUser` response for a fictional account
  (`investigator@example.com`).
