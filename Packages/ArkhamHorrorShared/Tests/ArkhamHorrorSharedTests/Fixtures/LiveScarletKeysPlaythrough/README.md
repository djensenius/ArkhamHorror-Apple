# Live Scarlet Keys playthrough fixtures

These files are local Apple regression fixtures for task-1.20.10, not vendored
contract fixtures. They were captured from the no-bypass live harness while driving
campaign `09` (`The Scarlet Keys`) as Roland Banks, then reserialized with sorted
keys before being checked in.

Source references:
- Repository: `https://github.com/djensenius/ArkhamHorror` at commit
  `c601a7a967e24628502976ae61a283f9ac0fe7ae` for the fork server binary used in
  the live run.
- Locale catalog served during capture: fork catalog worktree commit
  `f454ccb9fb789739c666a9cbd74d3fdc14a81fb9`, catalog revision
  `1.df693dd151c5aee4391f7690e7320870`.
- Server prompt source: `backend/arkham-api/library/Arkham/Campaign/Campaigns/TheScarletKeys.hs`
  emits `PickCampaignSpecific "embark"` for the world map at lines 168-200 and
  handles `CampaignSpecific "travel"`, `"travelVia"`, and `"travelWithTicket"`
  at lines 212-223.
- Web rendering source: `frontend/src/arkham/components/StoryQuestion.vue:167-170`
  recognizes `PickCampaignSpecific` with contents key `embark`, and
  `frontend/src/arkham/components/StoryQuestion.vue:262-263` renders
  `TheScarletKeys/WorldMap.vue`; `frontend/src/arkham/components/TheScarletKeys/WorldMap.vue:168-194`
  sends `CampaignSpecificAnswer` payloads, while
  `frontend/src/arkham/components/TheScarletKeys/WorldMapDrawerContent.vue:62-83`
  exposes travel, expedited-ticket travel, and travel-without-stopping actions.
- Capture: no-bypass Apple live harness trace, game
  `db8a83c4-b73b-4c19-83b3-5747cf87299d`, scenario `c09501`, question version
  `145`, raw question tag `PickCampaignSpecific`.
- `roland-c09501-q145-embark-world-map.json` SHA-256 after sorted-key
  reserialization: `afa1f258aea8e3a166c26a5e1c79a4f5156e3bc4835ceb1df1702c2cb83ad0e0`.
- `roland-c09501-q145-embark-world-map-has-ticket.json` is derived from the
  capture above by changing only `questionPresentation.value.hasTicket` to `true`,
  so it covers expedited-ticket rendering for both green destinations (where web
  adds 1 to raw travel time before comparing) and ordinary non-green destinations.
  Its SHA-256 after sorted-key reserialization is
  `3c5e87461efebef4619d886e45a417e0ffe23a0a94f3a923abdea469a206f98b`.
