# Live playthrough harness

This env-gated harness is for live no-bypass playthrough verification. It is not part of normal CI and normal `mise run test` skips the live run unless `ARKHAM_LIVE_SERVER_URL` is set. The non-live configuration tests still run normally.

The harness defaults to the original Night of the Zealot behavior: campaign `01`, Easy difficulty, and all five core investigators. It now also accepts a different campaign id or a standalone scenario id through environment variables and writes target-named summaries/traces.

## Source parity with the web create flow

The harness creates games through the Apple `AppModel.createGame` path, which posts the same `CreateGameRequest` shape the web uses. Read-only references in the fork frontend:

- `frontend/src/arkham/api.ts` `newGame(...)` posts `deckIds`, `playerCount`, `campaignId`, `scenarioId`, `difficulty`, `campaignName`, `multiplayerVariant`, `includeTarotReadings`, `options`, `strictAsIfAt`, `asIfRuling`, `ultimatumsAndBoons`, and `achievementsEnabled` to `arkham/games`.
- `frontend/src/arkham/views/NewCampaign.vue` selects either `campaignId` or `scenarioId`, swaps Return To ids where the frontend catalog exposes them, passes campaign variant options as `{ tag: 'CampaignVariant', contents: <key> }`, and disables achievements for standalone scenarios.
- Campaign ids come from `frontend/src/arkham/data/campaigns.json`; standalone and side-story ids come from `frontend/src/arkham/data/scenarios.ts` / `side-stories.json` data imported by the create view.
- The web considers a game finished when `game.gameState.tag === 'IsOver'` (`Home.vue`, `Game.vue`, and replay/admin views). The harness uses the same server state instead of any scenario-id-specific terminal check.

## Environment variables

Required to run the live harness:

- `ARKHAM_LIVE_SERVER_URL` — base URL for the live fork server/proxy, for example `http://127.0.0.1:3010`.

Target selection:

- `ARKHAM_LIVE_CAMPAIGN_ID` — campaign id to start. Defaults to `01` when no standalone scenario is set.
- `ARKHAM_LIVE_SCENARIO_ID` — standalone scenario id to start. Set either this or `ARKHAM_LIVE_CAMPAIGN_ID`, not both.
- `ARKHAM_LIVE_DIFFICULTY` — `Easy`, `Standard`, `Hard`, or `Expert`; defaults to `Easy`.
- `ARKHAM_LIVE_INVESTIGATOR_CODES` — comma-separated core investigator card codes. Defaults to all five core investigators for campaign `01`, otherwise Roland (`01001`).

Supported web-shaped create options:

- `ARKHAM_LIVE_CAMPAIGN_VARIANT` / `ARKHAM_LIVE_CAMPAIGN_VARIANTS` — comma-separated variant keys encoded as `CampaignVariant` options, for campaigns where the server supports them.
- `ARKHAM_LIVE_STRICT_AS_IF_AT` — `true`/`false`; when present the harness also sends the matching web `asIfRuling` value (`chapter2` for true, `chapter1` for false).
- `ARKHAM_LIVE_ULTIMATUMS_AND_BOONS` — comma-separated known ultimatum/boon tags.
- `ARKHAM_LIVE_INCLUDE_TAROT_READINGS` — `true`/`false`; defaults to `false`.
- `ARKHAM_LIVE_ACHIEVEMENTS_ENABLED` — `true`/`false`; defaults to web parity (`true` for campaigns, `false` for standalone scenarios).

Diagnostics/output:

- `ARKHAM_LIVE_PLAYTHROUGH_TIMEOUT` — seconds before the bot records a timeout; defaults to `900`.
- `ARKHAM_LIVE_RESULT_PATH` — markdown summary path. Defaults to `/tmp/arkham-logs/playthrough-results-<target>.md`; the Night of the Zealot default also writes the legacy `/tmp/arkham-logs/playthrough-results.md`.
- `ARKHAM_LIVE_DIAGNOSTIC_BYPASS_UNSUPPORTED=1` — opt-in diagnostic bypass described below.

Trace files are written as `/tmp/arkham-logs/playthrough-trace-<target>-<investigator>.jsonl`.

## Completion and failure behavior

The harness polls the server snapshot and passes only when `PublicGame.gameState` is `IsOver`, matching the web finished-game state. It records campaign resolutions from the server campaign object by reading `completedSteps` and `resolutions`; there are no hard-coded Night of the Zealot scenario ids. Standalone scenarios record the terminal scenario id when the server reports `IsOver`.

The harness still fails on any prompt the Apple app cannot render or cannot submit. Unresolved `$` labels and unsupported semantic choices remain unpressable unless the diagnostic bypass is explicitly enabled.

## Local catalog-backed server setup used for round 3

1. In a fork worktree with the task-1.2.12 server branch checked out, install frontend dependencies once:
   ```sh
   npm --prefix frontend ci --ignore-scripts
   ```
2. Generate the same public locale catalog artefacts production publishes:
   ```sh
   rm -rf scripts/__pycache__ ./.locale-catalog-python.*
   LOCALE_CATALOG_MISE_ROOT="$HOME/.local/share/mise" mise run locale-catalog:generate
   ```
   This writes `frontend/public/locale-catalog/manifest.json` plus content-addressed chunks.
3. Derive the six backend pointer variables from that manifest, exactly like `scripts/check-locale-catalog-settings.py`:
   - `ARKHAM_LOCALE_CATALOG_MANIFEST_URL` = manifest `manifestPath` (`/locale-catalog/manifest.json`)
   - `ARKHAM_LOCALE_CATALOG_REVISION` = manifest `catalogRevision`
   - `ARKHAM_LOCALE_CATALOG_SCHEMA_VERSION` = manifest `schemaVersion`
   - `ARKHAM_LOCALE_CATALOG_DEFAULT_LOCALE` = manifest `defaultLocale`
   - `ARKHAM_LOCALE_CATALOG_LOCALES` = comma-joined manifest locale list
   - `ARKHAM_LOCALE_CATALOG_MANIFEST_SHA256` = SHA-256 of the exact manifest bytes
4. Run the fork backend with those six variables, Postgres 14, and the usual local API settings. For task-1.20.1 live verification the backend listened on `127.0.0.1:3012`.
5. Put a same-origin local proxy in front of it on `127.0.0.1:3010`:
   - `/locale-catalog/**` is served from `frontend/public/locale-catalog` with `Content-Type: application/json` and `X-Content-Type-Options: nosniff`.
   - all other HTTP requests and WebSocket upgrades are proxied to `127.0.0.1:3012`.

The Apple app then sees `GET http://127.0.0.1:3010/api/v1/capabilities`, resolves the same-origin manifest URL to `http://127.0.0.1:3010/locale-catalog/manifest.json`, and verifies the manifest and chunks through the production `LocaleCatalogLoader` path: exact SHA-256, closed schema validation, chunk digest/size checks, JSON media type, and `nosniff`.

## Diagnostic unsupported-choice bypass

Set `ARKHAM_LIVE_DIAGNOSTIC_BYPASS_UNSUPPORTED=1` only when the goal is to finish a campaign and catalogue native rendering gaps. The harness still tries the production `AppModel.submitBasicChoice` path first. If the app refuses a server-selectable choice as `unsupportedChoice`, the harness records that prompt/choice in the JSONL trace and sends the same `Answer` payload directly over the already-open live WebSocket so the server can continue.

The bypass is deliberately limited to the `.unsupportedChoice` result. It never answers `.readOnly` prompts, including update-required/binding-drift prompts, legacy-server prompts, another-player prompts, or disconnected prompts; those remain harness failures so safety fences stay visible.

This is intentionally test-only and does not make unsupported UI pressable in the app. Use traces generated with this flag to create rendering/catalog/server follow-up tasks.
