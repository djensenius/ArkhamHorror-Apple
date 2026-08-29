/// Phantom tag distinguishing ``PlacementKind``.
enum PlacementKindTag: Sendable {}
/// Where an entity currently sits on the board (`Arkham.Placement`'s tag). Modeled as an
/// ``OpenStringEnum`` (rather than a closed Swift enum) even though the schema currently
/// enumerates this set exactly, because ``Placement`` is a response-side value: an
/// unrecognized future tag must still decode losslessly instead of failing the entire
/// entity it belongs to.
typealias PlacementKind = OpenStringEnum<PlacementKindTag>

extension PlacementKind {
    static let atLocation = PlacementKind("AtLocation")
    static let attachedToLocation = PlacementKind("AttachedToLocation")
    static let inPlayArea = PlacementKind("InPlayArea")
    static let inThreatArea = PlacementKind("InThreatArea")
    static let facedownInThreatArea = PlacementKind("FacedownInThreatArea")
    static let stillInHand = PlacementKind("StillInHand")
    static let hiddenInHand = PlacementKind("HiddenInHand")
    static let onTopOfDeck = PlacementKind("OnTopOfDeck")
    static let stillInDiscard = PlacementKind("StillInDiscard")
    static let stillInEncounterDiscard = PlacementKind("StillInEncounterDiscard")
    static let attachedToEnemy = PlacementKind("AttachedToEnemy")
    static let attachedToTreachery = PlacementKind("AttachedToTreachery")
    static let attachedToAsset = PlacementKind("AttachedToAsset")
    static let attachedToAct = PlacementKind("AttachedToAct")
    static let attachedToAgenda = PlacementKind("AttachedToAgenda")
    static let nextToAgenda = PlacementKind("NextToAgenda")
    static let nextToAct = PlacementKind("NextToAct")
    static let inVehicle = PlacementKind("InVehicle")
    static let attachedToInvestigator = PlacementKind("AttachedToInvestigator")
    static let asSwarm = PlacementKind("AsSwarm")
    static let unplaced = PlacementKind("Unplaced")
    static let limbo = PlacementKind("Limbo")
    static let global = PlacementKind("Global")
    static let outOfPlay = PlacementKind("OutOfPlay")
    static let near = PlacementKind("Near")
    static let inTheShadows = PlacementKind("InTheShadows")
    static let outOfGame = PlacementKind("OutOfGame")
    static let inPosition = PlacementKind("InPosition")
}

/// Where an entity currently sits on the board (`Arkham.Placement`). `contents` varies by
/// tag (a location/investigator/enemy/etc id, a nested placement, a position, or nothing
/// for the zero-argument tags) and is intentionally left broad since fully typing every
/// payload shape is out of scope for this contract slice. `contents`'s absence, explicit
/// `null`, and a present value are all distinct wire states the schema permits (`contents:
/// true` — fully unconstrained, including "absent entirely") so this preserves that
/// tri-state via ``OptionalField`` rather than collapsing "absent" and "null" together.
struct Placement: Sendable {
    let kind: PlacementKind
    let contents: OptionalField<JSONValue>
}

extension Placement: Equatable, Hashable {}

extension Placement: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind = "tag"
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(PlacementKind.self, forKey: .kind)
        contents = try OptionalField<JSONValue>.decode(from: container, forKey: .contents)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try contents.encode(to: &container, forKey: .contents)
    }
}
