# Schema 0.1.57 drift fixtures

Precomposition fixtures for task-1.35 (Apple repin to schema 0.1.57). They are **not**
part of the digest-governed `Fixtures/Contract` set and are not bound to
`ContractPin.current`; step 6 of task-1.35 re-vendors `Fixtures/Contract` from the merged
fork commit and may then replace these drift copies.

## Captured bytes

Byte-for-byte copies from the fork **upstream sync candidate for TASK-2.56**, worktree
`ArkhamHorror-task-2.56-upstream-sync` at provisional commit
`948608b28e2eb7b55865ada24f0a166a7208a420` (schemaRevision `0.1.57`,
nativeClientMinimumRevision `0.1.57`). That commit is provisional: the sync PR may be
rewritten before it merges, so the merge commit, not this SHA, is what the repin pins.

| File | Source path in the fork contracts tree | SHA-256 |
| --- | --- | --- |
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
