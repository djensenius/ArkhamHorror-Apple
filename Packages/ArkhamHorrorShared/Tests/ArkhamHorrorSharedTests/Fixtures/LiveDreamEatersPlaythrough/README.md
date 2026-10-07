# Live Dream-Eaters playthrough fixtures

These files are local Apple regression fixtures for task-1.20.7, not vendored contract
fixtures. They were captured from the Dream-Eaters live deck prompt path and reserialized
with sorted keys before being checked in.

Source references:
- Repository: `https://github.com/djensenius/ArkhamHorror` at commit
  `445cfbe90c59e0ac8b261669229030d196a2f831`.
- Server prompt source: `backend/arkham-api/library/Arkham/Campaign/Campaigns/TheDreamEaters.hs`
  emits `Msg.questionLabel (ikey' "theDreamEaters.question.chooseDeckForPartA") pid ChooseDeck`
  for Part A deck selection.
- Web locale source: `frontend/src/locales/en/theDreamEaters/base.json` maps
  `theDreamEaters.question.chooseDeckForPartA` to `Choose Deck For Part A`.
- Capture: the Apple live harness captured campaign `06` (`The Dream-Eaters`),
  scenario `BeyondTheGatesOfSleep`, at the Part A deck-selection prompt
  `QuestionLabel($theDreamEaters.question.chooseDeckForPartA, ChooseDeck)`.
- `question-presentation-dream-eaters-part-a-choose-deck.json` is the matching
  question-presentation payload for protocol version 2 / question version 10.

The fixtures stay under `Fixtures/LiveDreamEatersPlaythrough` so contract-provenance checks
continue to track only the governed fixtures in `Fixtures/Contract`.
