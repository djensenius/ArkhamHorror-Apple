# Test Fixtures

## Contract/manifest.json, Contract/capabilities.json, Contract/catalog.json, Contract/decks.json, Contract/game-lifecycle.json, Contract/game-list.json, Contract/get-game.json, Contract/game-update.json, Contract/mode-turn-zero.json, Contract/mode-campaign-only.json, Contract/mode-campaign-scenario.json, Contract/location-enemy-view.json, Contract/movement.json, Contract/act-no-advance-cost.json, Contract/investigator-unhealed-horror-negative.json, Contract/uuid-entity-map.json, Contract/card-code-entity-map.json

Vendored byte-for-byte from:
`djensenius/ArkhamHorror@7611b60abc1f0107abfba2c1939e4d170e20d948` (PRs #20, #22, #24, #45),
schema revision `0.1.20`.

These seventeen files, and only these seventeen, live under `Fixtures/Contract/` — a
dedicated subdirectory `ContractFixtureDigestTests` enumerates directly (via
`Bundle.module.urls(forResourcesWithExtension:subdirectory:)`), so adding, removing, or
substituting a file there is caught by comparing the directory's actual contents against
`ContractFixtureDigests.all`, not by maintaining a second hardcoded list. The full backend
contract manifest references many additional schema documents (OpenAPI, AsyncAPI, JSON
Schemas) that are **not** reproduced. See the backend repository for the authoritative
contract documents and the complete manifest.

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
`card-code-entity-map.json` are focused, sub-shape fixtures exercising specific governed
branches (`Data.These` mode sibling-key combinations and turn zero, the disjoint enemy
location view, an in-progress `Movement`, an act with no `advanceCost`, negative
`unhealedHorrorThisRound`, and the UUID-/`CardCode`-keyed entity map shapes) that are not
otherwise exercised by the single non-empty `get-game.json`/`game-update.json` fixture.

## token.json / whoami.json

Synthetic, hand-authored fixtures used by the authentication-session tests. They live
directly under `Fixtures/`, deliberately **outside** `Fixtures/Contract/`, since they are
**not** vendored from the backend, are unrelated to the contract pin, and contain **no**
real or reusable credentials:

- `token.json` — a `Token` response whose `token` is the obvious placeholder
  `fixture-token-not-a-real-credential`.
- `whoami.json` — a `CurrentUser` response for a fictional account
  (`investigator@example.com`).
