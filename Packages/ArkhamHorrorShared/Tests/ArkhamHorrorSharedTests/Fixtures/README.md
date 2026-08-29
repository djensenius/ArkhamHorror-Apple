# Test Fixtures

## Contract/manifest.json, Contract/capabilities.json, Contract/catalog.json, Contract/decks.json, Contract/game-lifecycle.json, Contract/game-list.json

Vendored byte-for-byte from:
`djensenius/ArkhamHorror@6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27` (PRs #20, #22, #24),
schema revision `0.1.12`.

These six files, and only these six, live under `Fixtures/Contract/` — a dedicated
subdirectory `ContractFixtureDigestTests` enumerates directly (via
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
directly.

## token.json / whoami.json

Synthetic, hand-authored fixtures used by the authentication-session tests. They live
directly under `Fixtures/`, deliberately **outside** `Fixtures/Contract/`, since they are
**not** vendored from the backend, are unrelated to the contract pin, and contain **no**
real or reusable credentials:

- `token.json` — a `Token` response whose `token` is the obvious placeholder
  `fixture-token-not-a-real-credential`.
- `whoami.json` — a `CurrentUser` response for a fictional account
  (`investigator@example.com`).
