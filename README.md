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
`macos-26`.

Install the pinned XcodeGen, SwiftFormat, and SwiftLint versions:

```sh
mise install
```

Select the stable Xcode developer directory once per shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## External production assignment replay

The assignment-continuation replay is a permanent **test-only** integration
driver. It boots the real `AppModel`, production capability/authentication,
catalog, asset, REST, and WebSocket paths, and sends
`BoardCommandController.jumpToActivePrompt` plus `primaryAction`. It does not
construct game state, implement assignment rules, or call a direct answer
bridge.

### Backend replay authority

As of Sunday, September 13, 2026, backend
`djensenius/ArkhamHorror#76` is squash-merged as
`21503e7dc82954b66ac9c24e7d34d9d1517549b8`. This repository is pinned to that
exact immutable commit and contract revision `0.1.34`. The merge defines
cross-client prompt SHA-256 over compact JSON with recursively sorted object
keys and bounds every replay CLI message drain.

It also defines deterministic checkpoint generation and validation, hashes the
exact uploaded multipart file bytes, persists an import receipt and player
remapping, embeds the clean running-server build identity, and exposes the
result through authenticated
`GET /api/v1/arkham/games/:id/replay-attestation`.

The governed response uses schema version 1:

   ```json
   {
     "schemaVersion": 1,
     "gameId": "<imported game UUID>",
     "gameGitRevision": "<40 lowercase hex source game revision>",
     "checkpointSha256": "<SHA-256 of exact uploaded file bytes>",
     "canonicalEnvelopeSha256": "<server-computed canonical digest>",
     "validatedCheckpoint": {
       "schemaVersion": 1,
       "contractSchemaRevision": "0.1.34",
       "prompt": {
         "questionVersion": "<validated prompt version>",
         "playerId": "<validated source player UUID>",
         "promptTag": "QuestionWithSource",
         "promptSha256": "<server-validated canonical prompt SHA-256>"
       },
       "checkpointGameSha256": "<canonical checkpoint-game digest>",
       "checkpointQueueSha256": "<canonical checkpoint-queue digest>"
     },
     "runningServerBuild": {
       "gitRevision": "<40 lowercase hex executable revision>",
       "gitTree": "<40 lowercase hex tree>",
       "sourceSha256": "<64 lowercase hex compiled-source digest>",
       "sourceClean": true,
       "attestation": "git-clean"
     },
     "importReceipt": {
       "schemaVersion": 1,
       "gameId": "<same imported game UUID>",
       "gameGitRevision": "<same source game revision>",
       "backendBuild": "<same object as runningServerBuild>",
       "checkpointSha256": "<same uploaded-file digest>",
       "canonicalEnvelopeSha256": "<same canonical digest>",
       "validatedCheckpoint": "<same validated checkpoint object>",
       "playerRemappings": [
         {
           "investigatorId": "<selected investigator>",
           "checkpointPlayerId": "<checkpoint player UUID>",
           "importedPlayerId": "<authenticated imported player UUID>",
           "livePlayerId": "<authenticated imported player UUID>",
           "stateRemapped": true
         }
       ],
       "receiptSha256": "<canonical receipt digest>"
     }
   }
   ```

The response comes only from the persisted result of the server validator,
never request parameters, an embedded digest by itself, or caller-provided
expected values. Apple requires lossless decode/re-encode equality, recomputes
the receipt digest from canonical sorted JSON, checks every duplicated
identifier and digest across the top level, validated checkpoint, build, and
receipt, requires the clean running backend build to match
`ContractPin.current.backendCommit`, and binds the single `WithFriends`
remapping to the selected investigator and authenticated live player. A
missing, redirected, malformed, stale, dirty, lossy, or mismatched response
aborts the run before any controller command.

The canonical-envelope digest binds the exact imported export plus generation
metadata, but does not authenticate caller-reported replay history. The
receipt and evidence therefore expose only state the server independently
validates: contract revision, prompt identity and digest, decoded game and
retained-queue digests, imported bytes, build identity, and player remapping.

### Produce and import the authoritative checkpoint

Using the immutable backend merge above:

1. Confirm `ContractPin.current` is
   `21503e7dc82954b66ac9c24e7d34d9d1517549b8` / `0.1.34`, then build the
   backend replay executable and production server from that exact clean
   revision.
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
   cd backend/arkham-api
   stack build --test --no-run-tests --pedantic --fast arkham-api
   DEVELOPMENT=true stack exec arkham-api
   ```

5. Preserve `assignment.checkpoint.json` byte-for-byte. The coordinator imports
   this exact byte sequence twice without a `multiplayerVariant` query
   override; the checkpoint's retained multiplayer mode must already be
   `WithFriends`. The route returns the complete bare `PublicGame` snapshot,
   not an `{ "id": ... }` receipt. Apple accepts only the exact non-redirected
   2xx JSON response under a 64 MiB ceiling, decodes it through the governed
   `PublicGameSnapshot` contract, and requires semantic decode/re-encode
   equality so ignored or unknown structure cannot supply the imported game
   ID. The importer must run the checkpoint validator and persist its separate
   attestation receipt before returning. Apple then reads each imported game
   through the authenticated production GET and requires schema-version-1
   attestation before submitting anything.

### Run both Apple cases

Invoke the production launcher only through its canonical committed regular-file
path; launcher symlinks and copies beside another Swift package are rejected.
Before any checkpoint, output, or token path is placed in a subprocess
environment, the launcher invokes fixed `/usr/bin/git` under `env -i`, verifies
the exact canonical repository top-level and origin, requires the clean
worktree's `HEAD` to be the audited follow-up commit that owns this launcher,
and binds the committed `ArkhamHorrorShared` package tree and manifest bytes.
Inherited `GIT_DIR`, `GIT_WORK_TREE`, config, object-directory, replacement-ref,
attribute, and namespace overrides cannot influence these checks.

The launcher never builds or runs the credentialed driver from that mutable
working tree. It creates a fresh private mode-0700 detached Git worktree from
the verified commit under a fixed trusted scratch parent, then independently
requires the materialized checkout's canonical top-level, commit, tree, index,
package tree, and detached state to match. Before building, its status includes
ignored paths and must be completely empty, so target-local ignored Swift
sources such as `DerivedData/*.swift` cannot enter the compilation.

The launcher builds and lists tests only in that committed checkout without any
credential paths. It requires exactly one complete driver identifier, rejects
any additional identifier sharing the driver prefix, revalidates both source
and materialized identities, and only then runs the already-built test with an
anchored complete-function filter and `--skip-build`. The Swift driver performs
its independent compile-time repository-root, clean-worktree, and `HEAD`
verification before recording the Apple revision. On every exit, the launcher
checks the recorded scratch and checkout device/inode identities before using
fixed `/usr/bin/git worktree remove`; it removes only that registered worktree
and its now-empty private parent.

The production launcher is fixed to:

```text
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
```

It verifies the Apple Xcode signature and pinned path, rejects executable and
toolchain overrides, and launches under `env -i` with a fixed `PATH`. There is
no production `curl`, Python, Git, filter, or dependency-injection override.
Install/select Xcode at that path before running.

Create a private mode-0600 token file. The credential is never placed in an
argument vector or subprocess environment:

```sh
set +x
TOKEN_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/arkham-replay-token.XXXXXX")"
TOKEN_FILE="${TOKEN_DIRECTORY}/token"
cleanup_replay_token() {
  /bin/rm -f -- "${TOKEN_FILE}"
  /bin/rmdir -- "${TOKEN_DIRECTORY}" 2>/dev/null || true
  unset TOKEN_FILE TOKEN_DIRECTORY REPLAY_TOKEN
}
trap cleanup_replay_token EXIT
trap 'exit 130' HUP INT TERM
(umask 077; : >"${TOKEN_FILE}")
/bin/chmod 600 "${TOKEN_FILE}"
IFS= read -r -s -p 'Backend token: ' REPLAY_TOKEN
printf '\n'
printf '%s\n' "${REPLAY_TOKEN}" >"${TOKEN_FILE}"
unset REPLAY_TOKEN
```

The server URL is parsed canonically before either input is opened. HTTPS is
accepted; HTTP is accepted only for the literal numeric loopback authorities
in the strict four-octet `127.0.0.0/8` form or `[::1]`. `localhost`, remote
cleartext, userinfo, query, fragment, default-port aliases, percent-encoded
authorities, and normalized spellings are rejected.

Invoke the launcher. The output directory must be an absolute path that does
not already exist:

```sh
set +x
export ARKHAM_REPLAY_BASE_URL='http://127.0.0.1:3000'
export ARKHAM_REPLAY_INVESTIGATOR_ID='c01234'
export ARKHAM_REPLAY_ENEMY_ID='<exact enemy wire identity>'
export ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION='<ContractPin.current revision>'
export ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION='<capabilities localeCatalog.catalogRevision>'
export ARKHAM_REPLAY_DEADLINE_SECONDS=60

CHECKPOINT="$(pwd -P)/assignment.checkpoint.json"
OUTPUT_DIRECTORY="${HOME}/.arkham-horror-replay/run-001"

Scripts/run-production-assignment-replay.sh \
  "${CHECKPOINT}" \
  "${OUTPUT_DIRECTORY}" \
  "${TOKEN_FILE}"
```

The shell only forwards non-secret configuration and the three paths. One
globally bounded Swift coordinator then:

1. Creates and retains the mode-0700 output directory through descriptor-bound,
   no-follow filesystem operations.
2. Opens the checkpoint and mode-0600 token through verified ancestor
   descriptors and reads each retained file descriptor exactly once.
3. Imports, authenticates, and attests both fresh games before either controller
   can submit an answer.
4. Requires both imports to be distinct and to return identical validator and
   clean server-build authority for the exact uploaded bytes.
5. Runs and persists the damage-first case, then proceeds to the horror-first
   `AppModel` and controller only after complete first-case success.
6. Publishes success only after both compact canonical artifacts independently
   decode, digest, and validate; otherwise it removes partial anchored output.

The same outer `ProductionReplayDriver` deadline bounds both imports, both
authenticated GETs and attestations, capability/catalog/asset/session startup,
controller actions, reconciliation, and output publication. Setup networking
uses redirect-rejecting, cookie/credential/cache-free production `URLSession`
transports with remaining-time request/resource timeouts and incremental
response-size ceilings.

Prompt version, prompt digest, checkpoint Game/queue digests, exact artifact
digest, canonical checkpoint-envelope identity, and the clean validator/import
backend build come only from the authenticated server attestation. The exact
two final files are:

- `damage-first.json`
- `horror-first.json`

Each is published only after the exact controller command path, one canonical
versioned `Answer`, authoritative before/after state, assignment delta, next
prompt/version/digest, checkpoint full-file and server-canonical envelope
digests, checkpoint Game/queue digests, validator/import server build, Apple
revision, game revision, contract, and catalog assertions pass. Evidence
schema `4.0.0` records all of those identities without claiming the
caller-authored generation history is authenticated.

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
