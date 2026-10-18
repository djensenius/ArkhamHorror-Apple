# Children of Blood live damage-assignment fixtures

These fixtures are captured raw `QuestionWithSource` JSON values from the Children of Blood live proof for task-1.21.3. They intentionally preserve the compact raw-question bytes embedded in the trace JSONL so parser tests exercise the exact backend prompt shape observed in the run.

Backend provenance:

- Fork/server commit: `06d5df29d991cc69c83637b1833be81045e8b113`

Fixtures:

- `question-live-cob-skids-q39-enemy-attack-damage-assignment.json`
  - Trace: `/tmp/arkham-logs/1213-cob-all-core-skids-otoole.jsonl`
  - Trace line: 236
  - Game: `1443bd2d-4016-4be6-8846-ebd442012870`
  - Player: `60275f66-3848-4517-b178-8190c8b74902`
  - Question version: 39
  - Live shape: terminal investigator `Assign 1 damage` with tail `[0,0,[{"contents":"c01003","tag":"InvestigatorTarget"}],[]]`.
- `question-live-cob-roland-q76-enemy-attack-damage-assignment.json`
  - Trace: `/tmp/arkham-logs/1213-cob-all-core-roland-banks.jsonl`
  - Trace line: 244
  - Game: `8eae40fb-4df5-450a-8aa0-98a99d22ff84`
  - Player: `f2ac030f-9953-4717-bf7a-ae6b16721812`
  - Question version: 76
  - Live shape: terminal investigator `Assign 1 damage` plus asset soak with `AssetComponent`, `DamageToken`, `AssignAssetDamageDeferred`, and `AssetTarget 77142f24-cb7e-41a4-b536-9580722ee63c`.
