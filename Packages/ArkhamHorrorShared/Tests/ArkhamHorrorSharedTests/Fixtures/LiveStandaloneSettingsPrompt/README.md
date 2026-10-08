# Live standalone settings prompt fixtures

Source: live task-1.20.12 run against `djensenius/ArkhamHorror` fork server worktree `/Users/david/Developer/ArkhamHorror/ArkhamHorror-task-2.30-dark-side-moon` at commit `c601a7a967e24628502976ae61a283f9ac0fe7ae`.

Captured from `/tmp/arkham-logs/playthrough-trace-scenario-86001-roland-banks.jsonl` during the no-bypass War of the Outer Gods standalone run with `ARKHAM_LIVE_SCENARIO_ID=86001`, `ARKHAM_LIVE_DIFFICULTY=Easy`, `ARKHAM_LIVE_INVESTIGATOR_CODES=01001`, and `ARKHAM_LIVE_BOT_SEED=0`.

The prompt has raw question `{"tag":"PickScenarioSettings"}` and semantic presentation `pickScenarioSettings` with `StandaloneSettingsAnswer`. The web side-story create flow has no setup settings in `frontend/src/arkham/data/side-stories.json:323-397` for this entry, so the native no-bypass answer is the exact empty settings payload `{"tag":"StandaloneSettingsAnswer","contents":[]}`.


`pick-scenario-specific-laid-to-rest.json` was captured from `/tmp/arkham-logs/playthrough-trace-scenario-90054-jim-culver.jsonl` after the Jim Culver retry for `ARKHAM_LIVE_SCENARIO_ID=90054`. It is the server's `PickScenarioSpecific "laidToRest.buildSpiritDeck"` prompt; the legal native default chooses the first `count` card codes from the RAW `cardCodes` list and answers as exact `ScenarioSpecificAnswer` contents `["laidToRest.buildSpiritDeck", {"cardCodes": [...]}]`.
