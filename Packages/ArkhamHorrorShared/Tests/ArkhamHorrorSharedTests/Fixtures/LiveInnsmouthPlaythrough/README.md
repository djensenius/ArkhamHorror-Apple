# Live Innsmouth playthrough fixtures

These files are local Apple regression fixtures for task-1.20.8, not vendored
contract fixtures. They were captured from the no-bypass live harness while driving
campaign `07` (`The Innsmouth Conspiracy`) as Roland Banks, then reserialized with
sorted keys before being checked in.

Source references:
- Repository: `https://github.com/djensenius/ArkhamHorror` at commit
  `c601a7a967e24628502976ae61a283f9ac0fe7ae` for the fork server binary used in
  the live run.
- Locale catalog served during capture: fork catalog worktree commit
  `f454ccb9fb789739c666a9cbd74d3fdc14a81fb9`, catalog revision
  `1.df693dd151c5aee4391f7690e7320870`.
- Server prompt source: `backend/arkham-api/library/Arkham/Enemy/Cards/TheInnsmouthConspiracy/ThePitOfDespair/TheAmalgam.hs`
  emits `labeledI18n "placeKeyOnTheAmalgam"` for keys on The Amalgam and
  `labeledI18n "theAmalgamAttacksYou"` for the alternate attack branch.
- Web locale source: `frontend/src/locales/en/theInnsmouthConspiracy/scenarios/thePitOfDespair.json`
  maps `theInnsmouthConspiracy.thePitOfDespair.label.placeKeyOnTheAmalgam` to
  `Place {key} key on the Amalgam` and
  `theInnsmouthConspiracy.thePitOfDespair.label.theAmalgamAttacksYou` to
  `The Amalgam attacks you`.
- Capture: no-bypass Apple live harness trace, game
  `61ab3b30-9798-4d3b-b70c-606d15c48491`, scenario `c07041`, question version
  `76`, raw question tag `ChooseOne`.
- `roland-c07041-q76-amalgam-key-unresolved-label.json` SHA-256 after sorted-key
  reserialization: `03f0a02a370ac2a23b6ac2076f9c7b039ae22235237ca38d43a92a0fc8b5344f`.

The fixture records a catalog gap seen during the live run: the catalog chunk marks
`theInnsmouthConspiracy.thePitOfDespair.label.placeKeyOnTheAmalgam` unsupported
because the `{key}` placeholder is classified as an unknown text-slot variable.
Apple must therefore leave that choice visible but unpressable and the live bot must
not select it. The alternate, resolved `$...theAmalgamAttacksYou` choice remains
pressable.
