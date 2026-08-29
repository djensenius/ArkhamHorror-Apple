/// Wire shape for `PublicGame`'s maps keyed by a UUID-backed newtype whose `ToJSONKey` is
/// `deriving newtype` from the wrapped UUID (`Arkham/Id.hs`): `enemies`, `assets`,
/// `treacheries`, `events`, `skills`, `concealed`, `question` (keyed by `PlayerID`), and
/// `cards` (keyed by `WireCardID`, `Arkham/Card/Id.hs`).
///
/// Entity value shapes remain an intentionally broad ``JSONValue`` placeholder — out of
/// scope for this map-key slice (see `public-game.schema.json`'s `uuidEntityMap` `$def`) —
/// while the key domain itself stays distinctly typed per entity kind so a future
/// snapshot diff/focus feature can compare/reference stable identities without
/// interpreting rules. Backed by ``UUIDKeyedMap`` (not a bare `[Identifier<Tag>: Value]`)
/// so a raw key that is not the backend's exact canonical lowercase UUID text, or that
/// collides with an already-seen key after normalization, fails to decode instead of
/// silently overwriting.
typealias UUIDEntityMap<Tag: Sendable> = UUIDKeyedMap<Tag, JSONValue>

/// Wire shape for `PublicGame`'s maps keyed by a `CardCode`-backed newtype whose
/// `ToJSONKey` is `deriving newtype` from `CardCode` (`Arkham/Id.hs` unless noted):
/// `stories` (`StoryId`), `scarletKeys` (`ScarletKeyId`,
/// `Arkham/Campaigns/TheScarletKeys/Key/Id.hs`), and `roundHistory`/`phaseHistory`/
/// `turnHistory` (`InvestigatorId`, `Map InvestigatorId History` in `Arkham/Game/Base.hs`).
///
/// Both the entity value shape *and* the specific key newtype identity remain an
/// intentionally broad placeholder for this map-key slice (see
/// `public-game.schema.json`'s `cardCodeEntityMap` `$def`, and its own standalone
/// `card-code-entity-map.schema.json` validation vehicle, which validate every one of
/// these four maps uniformly by the shared `cardCodeMapKey` pattern rather than
/// distinguishing `StoryId` from `ScarletKeyId` from `InvestigatorId`).
typealias CardCodeEntityMap = [CardCode: JSONValue]
