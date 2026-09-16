# Test Fixtures

## Contract fixtures

Vendored byte-for-byte from:
`djensenius/ArkhamHorror@f4d83466f6e36bea13d4b0c21204db56121b6585`,
schema revision `0.1.42`. Local validation can use the exact backend worktree as
`PROVENANCE_BACKEND_REPO_URL` and `LOCALE_CATALOG_BACKEND_REPO_URL`.

These 67 files, and only these 67, live under `Fixtures/Contract/` — a
dedicated subdirectory `ContractFixtureDigestTests` enumerates directly (via
`Bundle.module.urls(forResourcesWithExtension:subdirectory:)`), so adding, removing, or
substituting a file there is caught by comparing the directory's actual contents against
`ContractFixtureDigests.all`, not by maintaining a second hardcoded list. The full backend
contract manifest references many additional schema documents (OpenAPI, AsyncAPI, JSON
Schemas) that are **not** reproduced. The basic-choice and question-presentation schemas
are vendored here to bind raw question structure and semantic metadata to the same
immutable pin.
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
`djensenius/ArkhamHorror#76` merge. The current revision `0.1.42` manifest and
basic-choice schema continue to govern them. Unlike the former replay-derived draft, these
questions are generated through the real backend game engine, registered in the manifest,
schema-validated, and each backed by 16 published single-mutation negatives.

Both continuations retain the governed Ghoul Minion and Roland identities. Choosing damage
first produces the sole source-index-zero `Assign 1 horror`/`HorrorToken` continuation;
choosing horror first produces the symmetric `Assign 1 damage`/`DamageToken` continuation.
Each sends its exact direct amount followed by the production `(0 damage, 0 horror)`
completion message with both accumulated investigator-target arrays populated. Their
Answers preserve source index `0`, player UUID `00000000-0000-0000-0000-000000000001`,
and question version `7`. The 32 assignment-family negatives within the manifest's 625
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
this fixture within its 625 total regressions.

`question-player-window-engage-action.json` is the production post-Evade menu added by
`djensenius/ArkhamHorror#81`. The same Ghoul Minion remains available to Fight at source
index `4` and exposes Engage at source index `5` with production ability index `102`.
Engage requires the exact canonical `EnemySource`, retains every opaque ability/window
field, stays actionable only while that enemy remains in the newest projection, and
submits only the unchanged source index plus authoritative question version. Swift never
calculates or mutates engagement state. The backend manifest publishes three focused
Engage negatives for unknown action text, an alternate source constructor, and uppercase
UUID spelling within the manifest's 625 total regressions.

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
backend manifest publishes 55 focused round-transition mutations within its 625
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
manifest publishes 60 focused Roland mutations within its 625 total
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
counts. The manifest publishes 88 focused Cover Up mutations within its 625
total regressions.

The deterministic fixture hashes to
`0043cefb8ea59423b4283691ea6bbac816ef135b0b13fa380783004cd3613d95`.
Authenticated replay prompts can have a different digest because location and
skill-test UUIDs are runtime-generated; they remain governed by the same closed
shape and repeated-identity checks.

## Governed Gathering act advancement

`question-gathering-act-objective.json` is the exact production Q34
`PlayerWindowChooseOne` prompt. Its unchanged raw choice array has 13 entries;
source index `12` is the Gathering Act 1 objective for Roland Banks (`c01001`),
advancing act `c01108` through objective ability index `999` with a group clue
cost of two clues per investigator from anywhere.

`question-gathering-act-advance.json` is the exact production Q35 `ChooseOne`
follow-up. Its sole source index `0` advances the same act without duplicating
the objective cost or ability metadata. The paired
`question-presentation-gathering-act-objective.json` and
`question-presentation-gathering-act-advance.json` fixtures publish protocol
version `1`, the authoritative question version/kind/count, and generic
`advanceAct` descriptors over those original source indices. The presentation
schema publishes six focused Q34 mutations and one focused Q35 mutation within
the manifest's 625 total regressions.

The semantic descriptors are display, controller, and accessibility metadata
only. Apple must submit the unchanged source index and exact question version;
Haskell alone checks clue payment, legality, act advancement, and resulting
state. Native decoding accepts only the exact Q34 and Q35 `advanceAct`
descriptors. Q34 binding seals the complete raw choice array and complete
semantic descriptor array after replacing the eight runtime-generated UUIDs
with ordered placeholders, then requires both arrays to publish the same
ordered identities. Q35 binding seals its sole raw choice directly. Any changed
identity, ability, cost, message, source index, raw choice, or prompt shape
therefore remains update-required, while authenticated imports may regenerate
their opaque UUID identities without changing the governed shape.

## Governed Gathering movement entry

The ten movement-entry fixtures added by `djensenius/ArkhamHorror#91` govern
Q36 through Q39 after the Act 1 advancement:

- Q36 is the 11-choice movement menu. Cellar remains source index `9` and
  Attic remains source index `10`.
- Q37 is the exact `WindowChooseOne` location-entry forced ability for Cellar
  (`c01114`) or Attic (`c01113`), always at source index `0`.
- Q38 is the exact source-index-zero damage assignment for Cellar or horror
  assignment for Attic.
- Q39 is the next player window. Replay validates its prompt and authoritative
  board state but does not answer it.

The paired presentation fixtures publish only `move`, `resolveForcedAbility`,
`assignDamage`, and `assignHorror` descriptors that remain independently bound
to the raw source, card, location, investigator, token, and message identities.
Apple submits only the unchanged source indices and question versions; Haskell
alone moves Roland, resolves the location ability, and assigns damage or horror.
The manifest publishes 43 focused movement-entry mutations within its 625 total
regressions, including schema-valid raw changes to action/type, basic-action
expansion, cost, cancellation, additional-cost handling, cost bypass, and
target precedence that would otherwise change the pinned semantic descriptor.

## Authenticated Cover Up replay evidence

`Replay/cover-up-production-replay.json` is credential-free historical evidence
captured through the production `AppModel`, controller, authenticated checkpoint
import, REST, and WebSocket paths on September 14, 2026. It binds backend merge
`38d8b466b635e3c9a18995baccac8b67cb6984cc`, Apple implementation
`0d96d23a7b0f3d7dc06bec32b99d1208be48a5c3`, contract revision `0.1.40`,
and three distinct imported game/player identities.

The artifact records Q32 activation followed by both Q33 outcomes: using Cover
Up removes one clue from the treachery and leaves investigator/location clues
unchanged, while skipping leaves Cover Up unchanged and transfers one location
clue to Roland. Its third leg resubmits the stale Q32 answer while Q33 is active
and embeds the unchanged authoritative `GameUpdate`.

`ProductionCoverUpReplayEvidenceTests` separately pins the exact 456,305-byte
artifact SHA-256, recomputes every import-receipt and canonical snapshot digest,
validates the canonical answers and controller source indices, asserts both clue
deltas, and decodes the embedded resolved and stale responses through production
snapshot, strict Cover Up parser, projection, and actionability code. This
evidence lives outside `Fixtures/Contract/`: it proves an authenticated
historical execution and is not a replacement for the backend-governed contract
fixtures or an offline rules engine.

`replay-attestation.json` and `replay-attestation.schema.json` govern the durable
server authority returned after an authenticated checkpoint import. The production
replay coordinator uses that contract to bind the imported game, player remapping,
checkpoint bytes, backend build identity, and canonical replay envelope before
submitting any native action. `djensenius/ArkhamHorror#79` repairs the fixture's
canonical receipt digest and pins these bytes to immutable merge
`229b89da24546dc6f0a55b2d08ab0f047eb59808`; revision `0.1.42` rebinds that
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
