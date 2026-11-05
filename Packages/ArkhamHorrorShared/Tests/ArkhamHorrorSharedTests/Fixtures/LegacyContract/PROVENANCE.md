# Legacy contract compatibility fixtures

These fixtures are byte-for-byte copies of the pre-0.1.53 governed Apple contract fixtures at base commit `54cb6d39` (`origin/main` at the start of task-1.21.4), vendored to prove one app build still accepts older 0.1.48-0.1.52 server shapes while the governed `Fixtures/Contract` directory tracks the current pin (`ContractPin.current`).

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

## Schema 0.1.63 card-name label synthetic shapes

No files here: this section records the synthetic shapes `LabelCardNameSubstitutionTests` (task-1.2.23) builds inline. The card names come from the governed `Fixtures/LocaleCatalog/Contract` 0.1.63 `cardNames` chunks (en `0aa7e0e3…`, de `0d670d11…`, pl `97c056d4…`), vendored byte-for-byte at backend `05e537101118c5f8ceb70abae82ab7f59a355d93`. That commit's catalog has no label entry with a `{name}`/`{iname}` placeholder, so the label entries and wire labels are synthetic. Source paths are under `backend/arkham-api/library/` and `frontend/src/locales/` at backend `05e537101118c5f8ceb70abae82ab7f59a355d93`.

- Wire labels (synthetic): `$label.discardName __name=s:"01159" name=s:"Swarm of Rats"` follows `Arkham/Asset/Assets/DarkRitual.hs:30` (`cardNameVar attrs $ ikey' "label.discardName"`), and `$drew __iname=s:"01003" __name=s:"01159" iname=s:"\"Skids\" O'Toole" name=s:"Swarm of Rats"` follows `Arkham/Game/Runner.hs:2429` (`cardNameVar card $ investigatorNameVar investigator`, `ikey' "drew"`). Both use the `varStr` encoding (sorted `k=s:"…"` pairs) and the `cardNameVar`/`investigatorNameVar` variables of `Arkham/I18n.hs`. The card codes are Night of the Zealot cards present in the vendored packs; `90001` (an en-only synthetic `cardNames` entry) and `99999` (absent everywhere) exercise the fallbacks.
- en catalog entries (synthetic): `label.discardName` "Discard {name}" (`frontend/src/locales/en/label.json:65`) and `drew` "{iname} drew {name}" (`frontend/src/locales/en/base.json:246`), in the catalog chunk node format.
- de catalog entries (synthetic, no upstream text): `label.discardName` "{name} ablegen" and `drew` "{iname} zog {name}". The fork has no de label text for these keys. pl is a card-only locale and uses the en label entries through its fallback.
- task-1.42 reuses the `drew` entries and the same variables in other shapes (synthetic): a story i18n entry (`FlavorTextEntry.i18n(key: "drew", variables: {...})`, string values) in `LabelCardNameSubstitutionTests`, and in `GameLogPresentationTests` a typed `GameLogPart.i18n(key: "drew", …)` with `.text` values plus the legacy `$drew …` wire text above. The number-code shapes `__name` = JSON number `1159` and legacy `__name=i:1159` are synthetic negative cases: the server's `cardNameVar` always sends `__name` as a string.

## Lazy `cardNames` pack synthetic shapes (task-1.40)

No files here: `LocaleCatalogDeferredPackTests` serves the governed `Fixtures/LocaleCatalog/Contract` 0.1.63 manifest and chunks byte-for-byte (backend `05e537101118c5f8ceb70abae82ab7f59a355d93`). Its only synthetic bytes are negative cases: a governed `cardNames` chunk (en `0aa7e0e3…` from the transport, de `0d670d11…` on disk) with one byte flipped, which must fail the descriptor's pinned SHA-256.
