# Schema 0.1.57 drift fixtures

Precomposition fixtures for task-1.35 (Apple repin to schema 0.1.57). They are **not**
part of the digest-governed `Fixtures/Contract` set and are not bound to
`ContractPin.current`; step 6 of task-1.35 re-vendors `Fixtures/Contract` from the merged
fork commit and may then replace these drift copies.

## Captured bytes

Byte-for-byte copies from the fork **upstream sync candidate for TASK-2.56**, worktree
`ArkhamHorror-task-2.56-upstream-sync`. The verified candidate is the sync head
`dd9bf9030499458cff90d0ecbdd51782a5685346` (djensenius/ArkhamHorror#247, schemaRevision
`0.1.57`, nativeClientMinimumRevision `0.1.57`): all 17 files below are byte-identical at
that commit. The candidate is still provisional: the sync PR may change before it merges,
so the merge commit, not this SHA, is what the repin pins.

History: the files were first copied at candidate commit
`948608b28e2eb7b55865ada24f0a166a7208a420` and re-checked byte-identical at
`398c660b1234127868372b85726d6526673ec361` before being re-checked at `dd9bf903`.

| File | Source path in the fork contracts tree | SHA-256 |
| --- | --- | --- |
| `game-list.json` | `contracts/fixtures/game-list.json` | `15a68bfc25bdb5e73b4876ef4e7bbf97c66666bf2e185a6fbbb117ab6fe6ca80` |
| `game-unarchive-failed.json` | `contracts/fixtures/game-unarchive-failed.json` | `efec46cf0b4e4fe26d6cd56a56ed6d87edaa259cdd0109486032064a1bb2ec6c` |
| `game-unarchived.json` | `contracts/fixtures/game-unarchived.json` | `c3f84c0306025fc9f7275eb1c9735f7b63644ad1a8bd9ba693e17453924c7c28` |
| `game-update.json` | `contracts/fixtures/game-update.json` | `d53eb5492e82698f393921d3d8d033f13f5d54df50453d0b2095bec043a6757e` |
| `game-watcher-count.json` | `contracts/fixtures/game-watcher-count.json` | `8bccfde3a9cd97ec9e10ae21a840bafa8ea4700783df3fb43320fc25b6e3b531` |
| `get-game.json` | `contracts/fixtures/get-game.json` | `21ede54dd82f648d1487b8aae3299f9f37e5b4e2085f6c269d5cb9f5a7062892` |
| `investigator-unhealed-horror-negative.json` | `contracts/fixtures/investigator-unhealed-horror-negative.json` | `56f3d6439b9d4572d801dbe69218210311a0d11082cda915673fd4f5b69dfe25` |
| `mode-campaign-scenario.json` | `contracts/fixtures/mode-campaign-scenario.json` | `a050c83368de1269c2292955963a15e6980de606b17f2d794645a21a04ec6c77` |
| `mode-turn-zero.json` | `contracts/fixtures/mode-turn-zero.json` | `e8405055d4ebf675f9a30c6e2f5d89cd45cc87586fe1885f5bcc5a51e44fc209` |
| `question-agenda-horror-assignment.json` | `contracts/fixtures/question-agenda-horror-assignment.json` | `150e5f06f25aeccbe05599e24172958918740512dbdfe8912dfc90c8c7ebbbc0` |
| `question-enemy-attack-damage-assignment.json` | `contracts/fixtures/question-enemy-attack-damage-assignment.json` | `8a679a5b699a656acf23e258e0025e3f84c6f947bfdb9ed74bfcb503ec031ed1` |
| `question-enemy-attack-remaining-damage-assignment.json` | `contracts/fixtures/question-enemy-attack-remaining-damage-assignment.json` | `f8ba119a887d50a1401d6297e68a4b785d5fcaa0fb1dd4d93e432a27dc22f651` |
| `question-enemy-attack-remaining-horror-assignment.json` | `contracts/fixtures/question-enemy-attack-remaining-horror-assignment.json` | `404d79fb06181a8d371ce5f4d69ae11235251b871177940958197a04de246eed` |
| `question-gathering-attic-horror-assignment.json` | `contracts/fixtures/question-gathering-attic-horror-assignment.json` | `96c16e5cbe2110198208e3086904e047966c941d71aad530f2219c3e510f46cc` |
| `question-gathering-cellar-damage-assignment.json` | `contracts/fixtures/question-gathering-cellar-damage-assignment.json` | `24f0356426d4ec977da0911707f10fd4e10e3983bd945b7c2e7c6b007d580f55` |
| `question-generic-wrapped.json` | `contracts/fixtures/question-generic-wrapped.json` | `996572e6644785360f87a79b1d446c6b0ecf780de5cf6690d5c17cffa1bf7a49` |
| `question-presentation-representatives.json` | `contracts/fixtures/question-presentation-representatives.json` | `1ddc0325e020465a96f48c1642c0435ec5b322ad1b5925a3154348a8d485e3c8` |

## Synthetic shapes

Shapes the sync candidate has no captured bytes for are built inline in the tests from the
Haskell encoders, and each test names its source. They are labelled synthetic there.

- `Schema157BoardFieldsTests` populated and malformed values (synthetic): inline edits of
  the captured `get-game.json`, shaped from the sync candidate's
  `contracts/schemas/{public-game,investigator,chaos-bag,mode,game-list}.schema.json`.
  The captured bytes carry only empty or null values for these fields.
- `Schema157QuestionFallbackTests.chooseFromCollection` (synthetic): the raw
  `ChooseFromCollection` question, the defaultOptions record encoding of
  `backend/arkham-api/library/Arkham/Question.hs:188`
  (`{tag, investigatorId, source, cardCodes}`), with card codes matching the captured
  `chooseFromCollection` representative. The answer index picks `cardCodes`
  (`Entity/Answer.hs:935`).
- `Schema157QuestionFallbackTests.turnPlayerQuestion` and `turnPlayerPresentation`
  (synthetic): the `ChooseTurnPlayer` prompt from `Arkham/Game/Runner.hs`
  (`questionLabel "$label.choosePlayerToTakeTurn"` over `ChooseOne [PortraitLabel iid
  [ChoosePlayer iid SetTurnPlayer|ResumeTurnPlayer]]`), and its presentation per
  `Arkham/Question/Presentation.hs` (`PortraitLabel` is a `chooseTarget` on the
  investigator).
- `Schema157SocketMessageTests` `RoomClosed` frames (synthetic):
  `{"tag":"RoomClosed","contents":"abandoned"|"maintenance"}`, from
  `Api/Arkham/Helpers.hs` (`closeAbandonedRoom`, `applyMaintenance`), encoded like the
  captured Contract `room-closed.json`.
- `Schema157MaintenanceTests` 503 responses (synthetic): `Retry-After: 120` and
  `{"maintenance":true,"since":<UTCTime>,"message":<Text>}` from
  `backend/arkham-api/library/Foundation.hs` `maintenanceMiddleware`, with the message
  text of `Api/Arkham/Maintenance.hs` `defaultMaintenanceMessage`.
