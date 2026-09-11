# ArkhamHorror-Apple

ArkhamHorror-Apple is the native SwiftUI client foundation for a semantic digital
card game on iOS, iPadOS, macOS, tvOS, and visionOS. Phase 0 is intentionally a
walking skeleton: it proves the shared UI, platform entry points, focus-driven
input, project generation, tests, and CI without pretending that game features
exist.

Official card art, playmat art, and other Arkham Horror assets are not included.

## Architecture

XcodeGen creates four thin application targets. Each target has its own entry
point under `Sources/Platforms` and depends on the local `ArkhamHorrorShared`
Swift package under `Packages/ArkhamHorrorShared`:

- `App`: observable application state and command dispatch
- `Domain`: pure server endpoint and status models
- `Presentation`: the shared SwiftUI shell
- `Input`: semantic commands and focus targets

The UI uses standard SwiftUI buttons and platform focus systems. It does not
simulate a pointer or tabletop physics.

### Story catalog artwork

Story image nodes use the selected server's public `/api/v1/site-settings`
`assetHost`, validated independently of catalog content. Missing/null settings
select the web client's hosted CDN; an empty setting uses the server origin.
Transport errors or unsafe hosts never silently select another source.
The catalog and its asset-source result share the existing profile/generation
fence and catalog retry action. A settings failure blocks image-bearing passages,
not otherwise-resolvable text-only stories. Retrying just the image source leaves
the verified catalog and its request/revision intact, including while offline.

`CatalogImageAsset` accepts only closed semantic artwork families and exact
PNG, JPEG, or AVIF paths below `/img/arkham/`. In particular,
`encounter-sets/` is not rewritten to `sets/`, and `.jpeg` is not changed to
`.jpg`. SVG, WebP, unknown roots, mismatched roles, traversal, and external URLs
remain unavailable rather than receiving placeholder artwork.

All platforms render decoded native images through the shared bounded
`AssetCacheService` and a per-view `AssetImageLoader`. The root injects one cache
across windows; disappearing/replaced images cancel their loaders. Supplied alt
text (or an accessible role label) accompanies loading, success, and explicit
retry/failure states. Safely representable references enable story actions;
network/decode failures remain visible and retryable, never placeholder success.
No official artwork is bundled.

Local image-cache initialization failures are reported as client-side failures
with a **Retry image support** action. Retrying reconstructs the shared cache and
reloads only the image source; once construction succeeds, all windows reuse that
one observed cache instance for the rest of the session, without requiring relaunch.

## Prerequisites

- macOS with Xcode 26 or newer
- [mise](https://mise.jdx.dev/)

The 26.0 deployment floor is intentional: the client targets the current
public Apple OS generation across every platform rather than carrying
compatibility branches for older SDKs. Required CI therefore runs on
`macos-26`; the beta Xcode path below is used for next-generation validation.

Install the pinned XcodeGen, SwiftFormat, and SwiftLint versions:

```sh
mise install
```

For the local beta Xcode installation, select the developer directory once per
shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

## External production assignment replay

The assignment-continuation replay is a permanent **test-only** integration
driver. It boots the real `AppModel`, production capability/authentication,
catalog, asset, REST, and WebSocket paths, and sends
`BoardCommandController.jumpToActivePrompt` plus `primaryAction`. It does not
construct game state, implement assignment rules, or call a direct answer
bridge.

### Current backend gate

As of September 11, 2026, backend PR
`djensenius/ArkhamHorror#76` is still unmerged at
`0d1bb54d1b40d48b742c7c796b577c92339bf2ea`, and its Stack check is failing.
It advances the native contract to `0.1.34`. This repository must therefore
remain pinned to backend
`5acc0237b216e3b70ebe30af1559ab0e627e4f56` / contract `0.1.33` until that PR
actually merges.

The production checkpoint import route already exists, but there is currently
no merged `0.1.34` replay executable, committed assignment-specific checkpoint,
or fixture service that seeds the exact live combined damage/horror prompt.
Consequently, the two external live runs are blocked. Do not fabricate client
state or bypass `AppModel` to work around this gate.

### Produce and import the authoritative checkpoint

After backend PR #76 merges:

1. Update `ContractPin.current` to the immutable merged backend commit and
   `0.1.34`, then build the backend replay executable from that clean revision.
2. Obtain a normal authenticated backend game export whose retained state can
   be replayed to the combined enemy-attack assignment prompt.
3. Create an exact answer plan whose `stopAt` binds the prompt player, version,
   tag, and canonical SHA-256. Generate and inspect the checkpoint with the
   backend-owned harness:

   ```sh
   mise run replay:harness -- game-export.json \
     --replay-script replay-plan.json \
     --checkpoint-output assignment.checkpoint.json \
     --simulate-server

   mise run replay:harness -- assignment.checkpoint.json \
     --inspect-checkpoint > assignment.inspection.json
   ```

4. Start the normal backend from the same clean revision with its database,
   authentication, locale catalog, and asset settings configured:

   ```sh
   cd backend
   make api.watch
   ```

5. Import the *same* checkpoint twice through the production authenticated
   route. `WithFriends` plus the exact investigator card code gives each import
   a new authenticated player identity while retaining the authoritative
   checkpoint:

   ```sh
   set +x
   export ARKHAM_REPLAY_BASE_URL=http://127.0.0.1:3000
   export ARKHAM_REPLAY_TOKEN='<production Token credential>'
   export ARKHAM_REPLAY_INVESTIGATOR_ID='c01234'

   import_checkpoint() {
     curl --fail-with-body --silent --show-error \
       -H "Authorization: Token ${ARKHAM_REPLAY_TOKEN}" \
       -F "debugFile=@assignment.checkpoint.json;type=application/json" \
       -F "investigatorId=${ARKHAM_REPLAY_INVESTIGATOR_ID}" \
       "${ARKHAM_REPLAY_BASE_URL}/api/v1/arkham/games/import?multiplayerVariant=WithFriends"
   }

   import_checkpoint > damage-first.import.json
   import_checkpoint > horror-first.import.json
   ```

   Keep the original checkpoint and its full-file SHA-256. The production
   importer intentionally persists only the typed game export, not replay
   provenance.

6. Read each imported game through the production authenticated GET before any
   answer is submitted:

   ```sh
   DAMAGE_GAME_ID="$(jq -er '.id' damage-first.import.json)"
   HORROR_GAME_ID="$(jq -er '.id' horror-first.import.json)"

   curl --fail-with-body --silent --show-error \
     -H "Authorization: Token ${ARKHAM_REPLAY_TOKEN}" \
     "${ARKHAM_REPLAY_BASE_URL}/api/v1/arkham/games/${DAMAGE_GAME_ID}" \
     > damage-first.game.json
   curl --fail-with-body --silent --show-error \
     -H "Authorization: Token ${ARKHAM_REPLAY_TOKEN}" \
     "${ARKHAM_REPLAY_BASE_URL}/api/v1/arkham/games/${HORROR_GAME_ID}" \
     > horror-first.game.json

   DAMAGE_PLAYER_ID="$(jq -er '.playerId' damage-first.game.json)"
   HORROR_PLAYER_ID="$(jq -er '.playerId' horror-first.game.json)"
   ```

   Verify both GETs expose the expected `.game.git`, one owner prompt, exact
   question version, `EnemyAttackSource`, enemy/investigator identities, and
   canonical prompt digest. Read the catalog revision from
   `/api/v1/capabilities`. These values are inputs to the fail-closed Apple
   driver; none are inferred or normalized.

### Run both Apple cases

The Apple worktree must be clean because the driver verifies its exact `HEAD`.
Create a private result directory outside the repository, do not enable shell
tracing, and run one isolated imported game per case:

```sh
set +x
install -d -m 700 "${HOME}/.arkham-horror-replay"

export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_DEADLINE_SECONDS=60
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_SERVER_BASE_URL="${ARKHAM_REPLAY_BASE_URL}"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_SERVER_PROFILE_ID='00000000-0000-0000-0000-000000000777'
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_AUTH_TOKEN="${ARKHAM_REPLAY_TOKEN}"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_BACKEND_REVISION='<merged commit pinned by ContractPin>'
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_APPLE_REVISION="$(git rev-parse HEAD)"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_CONTRACT_REVISION='0.1.34'
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_CATALOG_REVISION='<capabilities localeCatalog.catalogRevision>'
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_ENEMY_ID='<exact enemy UUID>'
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_INVESTIGATOR_ID="${ARKHAM_REPLAY_INVESTIGATOR_ID}"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_DIGEST='<64 lowercase hex>'
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_VERSION='<canonical nonnegative integer>'

run_assignment_replay() {
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CASE="$1"
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_GAME_ID="$2"
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_PLAYER_ID="$3"
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_RESULT_PATH="$4"
  swift test --package-path Packages/ArkhamHorrorShared --no-parallel \
    --filter AssignmentContinuationReplayDriverSuite
}

run_assignment_replay \
  damage-first-then-remaining-horror \
  "${DAMAGE_GAME_ID}" \
  "${DAMAGE_PLAYER_ID}" \
  "${HOME}/.arkham-horror-replay/damage-first.json"

run_assignment_replay \
  horror-first-then-remaining-damage \
  "${HORROR_GAME_ID}" \
  "${HORROR_PLAYER_ID}" \
  "${HOME}/.arkham-horror-replay/horror-first.json"
```

Do not set
`ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_OBSERVED_APPLE_REVISION`; the parent
injects it only after verifying the worktree. A successful run atomically
publishes one compact canonical JSON evidence file only after all controller,
submitted-answer, authoritative before/after, assignment-delta, continuation,
revision, and digest assertions pass.

## Commands

```sh
mise run generate
mise run project-check
mise run format-check
mise run lint
mise run test
mise run build
```

`project-check` regenerates `ArkhamHorror.xcodeproj` and fails when the checked-in
project differs from `project.yml`.

## Current limitations

Phase 0 has no gameplay, persistence, accounts, deck management, or live network
requests. The server card is a compile-time UI contract only, and platform icons
are not yet provided. Product planning is tracked in
[djensenius/ArkhamHorror#5](https://github.com/djensenius/ArkhamHorror/issues/5)
and
[djensenius/ArkhamHorror-Apple#5](https://github.com/djensenius/ArkhamHorror-Apple/issues/5).
