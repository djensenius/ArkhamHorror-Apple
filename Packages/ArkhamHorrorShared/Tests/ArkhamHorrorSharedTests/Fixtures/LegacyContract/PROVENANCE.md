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
