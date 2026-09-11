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

PR #76 adds checkpoint generation and validation, but it does **not** provide
the immutable production authority the live Apple proof now requires. The
production importer decodes an `ArkhamExport` and discards
`replayCheckpoint` provenance. It also does not attest the executable serving
the imported game. Consequently, a live run currently fails closed before any
controller command.

The backend must additionally:

1. Hash the exact uploaded checkpoint bytes before decoding them.
2. Persist immutable import metadata bound to the new game, authenticated
   imported player, remapped checkpoint player, and embedded checkpoint
   envelope.
3. Embed the running server executable revision at build time. `PublicGame.git`
   is the imported **game** revision and is not server build identity.
4. Expose an authenticated, game-bound
   `GET /api/v1/arkham/games/:id/replay-attestation` response:

   ```json
   {
     "schemaVersion": 1,
     "gameId": "<imported game UUID>",
     "playerId": "<authenticated imported player UUID>",
     "checkpointPlayerId": "<player UUID in checkpoint provenance>",
     "serverBuild": {
       "gitRevision": "<40 lowercase hex executable revision>",
       "gitTree": "<40 lowercase hex tree>",
       "sourceSha256": "<64 lowercase hex compiled-source digest>",
       "sourceClean": true,
       "attestation": "git-clean"
     },
     "gameRevision": "<40 lowercase hex imported game revision>",
     "checkpointArtifactSha256": "<SHA-256 of exact uploaded file bytes>",
     "checkpointEnvelopeSha256": "<replayCheckpoint.envelopeSha256>",
     "contractRevision": "0.1.34",
     "checkpointName": "<provenance checkpoint name>"
   }
   ```

The response must come only from server-owned persisted import metadata, never
request parameters or caller-provided expected values. The Apple driver
requires a clean build attestation, compares `serverBuild.gitRevision` to
`ContractPin.current`, binds both checkpoint digests to a securely reopened
local file, and compares `gameRevision` to both the checkpoint and
authoritative REST/WebSocket snapshots. A missing, redirected, malformed, or
mismatched response aborts the run. Do not add a client-side receipt or
direct-answer workaround.

### Produce and import the authoritative checkpoint

After PR #76 **and** the attested import service above merge:

1. Update `ContractPin.current` to the final immutable backend commit containing
   both changes and to `0.1.34`, then build the backend replay executable and
   production server from that exact clean revision. Do not pin #76's current
   unmerged head.
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

5. Preserve `assignment.checkpoint.json` byte-for-byte. The wrapper imports this
   same file twice through the production `WithFriends` route, reads both games
   through the authenticated production GET, and requires the attestation
   endpoint for each imported game before Apple submits anything.

### Run both Apple cases

The Apple worktree must be clean because the driver invokes `/usr/bin/git` with
a fixed environment, verifies the canonical repository root, rejects tracked
and untracked changes, and checks its exact `HEAD`.

Create a caller-owned mode-0600 token file without placing the credential in
curl's argument vector:

```sh
set +x
TOKEN_FILE="${HOME}/.arkham-horror-replay-token"
(umask 077; : >"${TOKEN_FILE}")
chmod 600 "${TOKEN_FILE}"
IFS= read -r -s -p 'Backend token: ' REPLAY_TOKEN
printf '\n'
printf '%s\n' "${REPLAY_TOKEN}" >"${TOKEN_FILE}"
unset REPLAY_TOKEN
```

Then invoke the fail-fast wrapper. The output directory must not already exist;
the wrapper creates it mode 0700:

```sh
set +x
export ARKHAM_REPLAY_BASE_URL='http://127.0.0.1:3000'
export ARKHAM_REPLAY_INVESTIGATOR_ID='c01234'
export ARKHAM_REPLAY_ENEMY_ID='<exact enemy wire identity>'
export ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION='0.1.34'
export ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION='<capabilities localeCatalog.catalogRevision>'
export ARKHAM_REPLAY_DEADLINE_SECONDS=60

CHECKPOINT="$(pwd -P)/assignment.checkpoint.json"
OUTPUT_DIRECTORY="${HOME}/.arkham-horror-replay/run-001"

Scripts/run-production-assignment-replay.sh \
  "${CHECKPOINT}" \
  "${OUTPUT_DIRECTORY}" \
  "${TOKEN_FILE}"

rm -f "${TOKEN_FILE}"
unset TOKEN_FILE
```

The wrapper uses `set -euo pipefail`. It stops before the second case if the
first fails, removes a newly created output directory on failure, and succeeds
only when two fresh compact canonical artifacts exist and independently verify
against the exact checkpoint bytes. It writes a generated authorization header
to a mode-0600 file and passes only that file path to curl, then removes the
header and intermediate import/GET responses and unsets the child token on
every exit path. The caller-owned token file is never deleted implicitly.

Prompt version and canonical digest come from checkpoint provenance, not
caller-provided values. Server executable identity comes only from the
authenticated server attestation. The two final files are:

- `damage-first.json`
- `horror-first.json`

Each is published only after the exact controller command path, one canonical
versioned `Answer`, authoritative before/after state, assignment delta, next
prompt, checkpoint full-file/envelope digests, Apple revision, server build
revision, game revision, contract, and catalog assertions pass.

## Commands

```sh
mise run generate
mise run project-check
mise run format-check
mise run lint
mise run test
mise run production-assignment-replay-selftest
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
