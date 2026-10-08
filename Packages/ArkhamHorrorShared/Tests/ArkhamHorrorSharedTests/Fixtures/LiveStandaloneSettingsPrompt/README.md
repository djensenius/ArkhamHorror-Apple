# Live standalone settings prompt fixtures

Source: live task-1.20.12 run against `djensenius/ArkhamHorror` fork server worktree `/Users/david/Developer/ArkhamHorror/ArkhamHorror-task-2.30-dark-side-moon` at commit `c601a7a967e24628502976ae61a283f9ac0fe7ae`.

The standalone empty-settings allow-list in the app is generated from `https://github.com/djensenius/ArkhamHorror` at the Apple contract pin `8453314123831e9fb1e7817e34190671b73b8ae0`, using the static web scenario data merged by `frontend/src/arkham/data/scenarios.ts` (campaign JSON files plus `side-stories.json`, excluding homebrew). Apple intentionally keeps an explicit Continue button where the web auto-submits `[]`, but only for scenario IDs whose web settings are absent or empty.

Captured from `/tmp/arkham-logs/playthrough-trace-scenario-86001-roland-banks.jsonl` during the no-bypass War of the Outer Gods standalone run with `ARKHAM_LIVE_SCENARIO_ID=86001`, `ARKHAM_LIVE_DIFFICULTY=Easy`, `ARKHAM_LIVE_INVESTIGATOR_CODES=01001`, and `ARKHAM_LIVE_BOT_SEED=0`.

The prompt has raw question `{"tag":"PickScenarioSettings"}` and semantic presentation `pickScenarioSettings` with `StandaloneSettingsAnswer`. The web side-story create flow has no setup settings in `frontend/src/arkham/data/side-stories.json:323-397` for this entry, so the native no-bypass answer is the exact empty settings payload `{"tag":"StandaloneSettingsAnswer","contents":[]}`.


`pick-scenario-specific-laid-to-rest.json` was captured from `/tmp/arkham-logs/playthrough-trace-scenario-90054-jim-culver.jsonl` after the Jim Culver retry for `ARKHAM_LIVE_SCENARIO_ID=90054`. It is the server's `PickScenarioSpecific "laidToRest.buildSpiritDeck"` prompt. The native view mirrors the web by making the player choose exactly `count` distinct cards from the RAW `cardCodes` list, preserving the selected order in the exact `ScenarioSpecificAnswer` contents `["laidToRest.buildSpiritDeck", {"cardCodes": [...]}]`. Fixed cards from `fixed` are shown display-only.
