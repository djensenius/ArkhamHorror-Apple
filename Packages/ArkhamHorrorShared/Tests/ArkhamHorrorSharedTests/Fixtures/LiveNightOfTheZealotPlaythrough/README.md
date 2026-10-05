# Live Night of the Zealot playthrough harness

This env-gated harness is for Backlog `task-1.2.12` automated verification. It is not part of normal CI; it only runs when `ARKHAM_LIVE_SERVER_URL` is set.

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
4. Run the fork backend with those six variables, Postgres, and the usual local API settings. In round 3 the backend listened on `127.0.0.1:3002`.
5. Put a same-origin local proxy in front of it on `127.0.0.1:3000`:
   - `/locale-catalog/**` is served from `frontend/public/locale-catalog` with `Content-Type: application/json` and `X-Content-Type-Options: nosniff`.
   - all other HTTP requests and WebSocket upgrades are proxied to `127.0.0.1:3002`.

The Apple app then sees `GET http://127.0.0.1:3000/api/v1/capabilities`, resolves the same-origin manifest URL to `http://127.0.0.1:3000/locale-catalog/manifest.json`, and verifies the manifest and chunks through the production `LocaleCatalogLoader` path: exact SHA-256, closed schema validation, chunk digest/size checks, JSON media type, and `nosniff`.

## Diagnostic unsupported-choice bypass

Set `ARKHAM_LIVE_DIAGNOSTIC_BYPASS_UNSUPPORTED=1` only when the goal is to finish a campaign and catalogue native rendering gaps. The harness still tries the production `AppModel.submitBasicChoice` path first. If the app refuses a server-selectable choice as `unsupportedChoice`, the harness records that prompt/choice in the JSONL trace and sends the same `Answer` payload directly over the already-open live WebSocket so the server can continue.

This is intentionally test-only and does not make unsupported UI pressable in the app. Use traces generated with this flag to create rendering/catalog/server follow-up tasks.
