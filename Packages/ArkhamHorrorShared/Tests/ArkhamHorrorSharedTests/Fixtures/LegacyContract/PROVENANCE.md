# Legacy contract compatibility fixtures

These fixtures are byte-for-byte copies of the pre-0.1.53 governed Apple contract fixtures at base commit `54cb6d39` (`origin/main` at the start of task-1.21.4), vendored to prove one app build still accepts older 0.1.48-0.1.52 server shapes while the governed `Fixtures/Contract` directory tracks the current 0.1.53 pin.

- `question-roland-defeat-reaction-pre-0.1.53.json` from `54cb6d39:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-roland-defeat-reaction.json`
- `question-round-end-forced-ability-pre-0.1.53.json` from `54cb6d39:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-round-end-forced-ability.json`

## Pre-0.1.57 `QuestionLabel` fixtures

These fixtures are byte-for-byte copies of the governed Apple contract fixtures at base commit `aee8908c0758b0267b57347ddfca327a6fac020b` (Apple `main` at the start of task-1.35; contract pin backend `9c75088611ca15ee3bbfe0c54b2fa4989b80ed50`, schema `0.1.55`). They keep the single nullable `QuestionLabel.card` shape that schema 0.1.57 replaced with `labelCards`, so one app build still proves it accepts 0.1.48-0.1.56 servers after `Fixtures/Contract` is re-vendored at 0.1.57.

- `question-agenda-horror-assignment-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-agenda-horror-assignment.json`
- `question-enemy-attack-damage-assignment-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-enemy-attack-damage-assignment.json`
- `question-enemy-attack-remaining-damage-assignment-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-enemy-attack-remaining-damage-assignment.json`
- `question-enemy-attack-remaining-horror-assignment-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-enemy-attack-remaining-horror-assignment.json`
- `question-gathering-attic-horror-assignment-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-gathering-attic-horror-assignment.json`
- `question-gathering-cellar-damage-assignment-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-gathering-cellar-damage-assignment.json`
- `question-generic-wrapped-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/question-generic-wrapped.json`

## Pre-0.1.57 board fixtures

Byte-for-byte copies of the governed Apple contract fixtures at the same base commit `aee8908c0758b0267b57347ddfca327a6fac020b` (contract pin backend `9c75088611ca15ee3bbfe0c54b2fa4989b80ed50`, schema `0.1.55`; each is also byte-identical to that backend commit's `contracts/fixtures/<name>.json`). They have none of the optional board fields schema 0.1.57 added (`outcome`, `settingsCustomRandomWeaknessPools`, the investigator prohibitions and clue flags, `debugRevealedChaosTokens`, `sealedChaosTokens`), so the absent-field decoding stays proven after `Fixtures/Contract` moved to 0.1.57.

- `get-game-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/get-game.json`
- `game-list-pre-0.1.57.json` from `aee8908c:Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract/game-list.json`

## Schema 0.1.57 synthetic test shapes

No files here: this section records the synthetic shapes the task-1.35 tests build inline. It keeps the "Synthetic shapes" list of the removed `Fixtures/Schema157Drift/PROVENANCE.md`. The captured 0.1.57 bytes those tests use come from the governed `Fixtures/Contract` set: they were first vendored at backend `4db9946179ef8b7a242bd7e40c0a2d74990cf3e9` (schema 0.1.57) and are byte-identical at the current 0.1.63 pin (backend `05e537101118c5f8ceb70abae82ab7f59a355d93`). Neither commit has captured bytes for the shapes below, so the tests build them from the Haskell encoders, name their source, and label them synthetic. Source paths and line references are under `backend/arkham-api/library/` at backend `4db9946179ef8b7a242bd7e40c0a2d74990cf3e9`.

- `Schema157BoardFieldsTests` populated and malformed values (synthetic): inline edits of the governed `Fixtures/Contract/get-game.json`, shaped from `contracts/schemas/{public-game,investigator,chaos-bag,mode,game-list}.schema.json`. The captured bytes carry only empty or null values for these fields.
- `Schema157QuestionFallbackTests.chooseFromCollection` (synthetic): the raw `ChooseFromCollection` question, the defaultOptions record encoding of `Arkham/Question.hs:188` (`{tag, investigatorId, source, cardCodes}`), with card codes matching the captured `chooseFromCollection` representative. The answer index picks `cardCodes` (`Entity/Answer.hs:935`).
- `Schema157QuestionFallbackTests.turnPlayerQuestion` and `turnPlayerPresentation` (synthetic): the `ChooseTurnPlayer` prompt from `Arkham/Game/Runner.hs` (`questionLabel "$label.choosePlayerToTakeTurn"` over `ChooseOne [PortraitLabel iid [ChoosePlayer iid SetTurnPlayer|ResumeTurnPlayer]]`), and its presentation per `Arkham/Question/Presentation.hs` (`PortraitLabel` is a `chooseTarget` on the investigator).
- `Schema157SocketMessageTests` `RoomClosed` frames (synthetic): `{"tag":"RoomClosed","contents":"abandoned"|"maintenance"}`, from `Api/Arkham/Helpers.hs` (`closeAbandonedRoom`, `applyMaintenance`), encoded like the governed Contract `room-closed.json`.
- `Schema157MaintenanceTests` 503 responses (synthetic): `Retry-After: 120` and `{"maintenance":true,"since":<UTCTime>,"message":<Text>}` from `Foundation.hs` `maintenanceMiddleware`, with the message text of `Api/Arkham/Maintenance.hs` `defaultMaintenanceMessage`.
