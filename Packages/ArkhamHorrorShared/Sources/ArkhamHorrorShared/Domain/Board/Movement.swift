/// `Arkham.Movement.Destination = ToLocation LocationId | ToLocationMatching
/// LocationMatcher` (`backend/arkham-api/library/Arkham/Movement.hs`), derived with
/// Aeson's default `TaggedObject` sum encoding.
enum MovementDestination: Sendable {
    /// A specific `LocationId` destination.
    case toLocation(LocationID)
    /// A destination resolved by matching a `Arkham.Matcher.LocationMatcher`; contents are
    /// schema-unconstrained and out of scope for this contract slice.
    case toLocationMatching(JSONValue)
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// so nothing is lost; never encodable.
    case unknown(tag: String, rawObject: JSONValue)
}

extension MovementDestination: Equatable, Hashable {}

/// Thrown when encoding a ``MovementDestination`` whose tag this client build never
/// recognized.
enum MovementDestinationError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

extension MovementDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "ToLocation":
            self = try .toLocation(container.decode(LocationID.self, forKey: .contents))
        case "ToLocationMatching":
            self = try .toLocationMatching(container.decode(JSONValue.self, forKey: .contents))
        default:
            self = try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .toLocation(locationID):
            try container.encode("ToLocation", forKey: .tag)
            try container.encode(locationID, forKey: .contents)
        case let .toLocationMatching(contents):
            try container.encode("ToLocationMatching", forKey: .tag)
            try container.encode(contents, forKey: .contents)
        case let .unknown(tag, _):
            throw MovementDestinationError.cannotEncodeUnknownTag(tag)
        }
    }
}

/// `Arkham.Movement.MovementMeans = Direct | OneAtATime | Towards | Place | TowardsN Int`
/// (`backend/arkham-api/library/Arkham/Movement.hs`), derived with Aeson's default
/// `TaggedObject` sum encoding. Because `TowardsN` is not nullary, `allNullaryToStringTag`
/// does not apply: every constructor — including the 4 nullary ones — encodes as a
/// `TaggedObject` (`Direct` encodes as `{"tag":"Direct"}`, never a bare string).
enum MovementMeans: Sendable {
    case direct
    case oneAtATime
    case towards
    case place
    case towardsN(Int)
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// so nothing is lost; never encodable.
    case unknown(tag: String, rawObject: JSONValue)
}

extension MovementMeans: Equatable, Hashable {}

/// Thrown when encoding a ``MovementMeans`` whose tag this client build never recognized.
enum MovementMeansError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

extension MovementMeans: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        func nullaryCase() throws {
            try rejectPresentContents(
                container,
                contentsKey: .contents,
                tag: tag,
                codingPath: decoder.codingPath
            )
        }
        switch tag {
        case "Direct":
            try nullaryCase()
            self = .direct
        case "OneAtATime":
            try nullaryCase()
            self = .oneAtATime
        case "Towards":
            try nullaryCase()
            self = .towards
        case "Place":
            try nullaryCase()
            self = .place
        case "TowardsN":
            self = try .towardsN(container.decode(Int.self, forKey: .contents))
        default:
            self = try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct:
            try container.encode("Direct", forKey: .tag)
        case .oneAtATime:
            try container.encode("OneAtATime", forKey: .tag)
        case .towards:
            try container.encode("Towards", forKey: .tag)
        case .place:
            try container.encode("Place", forKey: .tag)
        case let .towardsN(value):
            try container.encode("TowardsN", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case let .unknown(tag, _):
            throw MovementMeansError.cannotEncodeUnknownTag(tag)
        }
    }
}

/// `Arkham.Movement.Movement` (`backend/arkham-api/library/Arkham/Movement.hs`), used by
/// `InvestigatorAttrs.investigatorMovement` (`Maybe Movement`) to represent an in-progress
/// move. Deep `Source`/`Target`/`Message` payloads stay broad and out of scope for this
/// contract slice; only the stable top-level keys and the closed `MovementMeans`/
/// `Destination` tags are constrained here.
struct Movement: Sendable {
    /// `Arkham.Source.Source`. Broad tagged union, out of scope for this contract slice.
    let moveSource: JSONValue
    /// `Arkham.Target.Target`. Broad tagged union, out of scope for this contract slice.
    let moveTarget: JSONValue
    let moveDestination: MovementDestination
    let moveMeans: MovementMeans
    let moveCancelable: Bool
    let movePayAdditionalCosts: Bool
    /// `[Arkham.Message.Message]` queued to run once this movement resolves. Broad and
    /// recursive, out of scope for this contract slice.
    let moveAfter: [JSONValue]
    let moveAdditionalEnterCosts: RuntimeCost
    let moveSkipEngagement: Bool
    let moveID: MovementID
    let moveForced: Bool
    let moveFromInPlay: Bool
}

extension Movement: Equatable, Hashable {}

extension Movement: Codable {
    private enum CodingKeys: String, CodingKey {
        case moveSource
        case moveTarget
        case moveDestination
        case moveMeans
        case moveCancelable
        case movePayAdditionalCosts
        case moveAfter
        case moveAdditionalEnterCosts
        case moveSkipEngagement
        case moveID = "moveId"
        case moveForced
        case moveFromInPlay
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moveSource = try container.decode(JSONValue.self, forKey: .moveSource)
        moveTarget = try container.decode(JSONValue.self, forKey: .moveTarget)
        moveDestination = try container.decode(MovementDestination.self, forKey: .moveDestination)
        moveMeans = try container.decode(MovementMeans.self, forKey: .moveMeans)
        moveCancelable = try container.decode(Bool.self, forKey: .moveCancelable)
        movePayAdditionalCosts = try container.decode(Bool.self, forKey: .movePayAdditionalCosts)
        moveAfter = try container.decode([JSONValue].self, forKey: .moveAfter)
        moveAdditionalEnterCosts = try container.decode(
            RuntimeCost.self,
            forKey: .moveAdditionalEnterCosts
        )
        moveSkipEngagement = try container.decode(Bool.self, forKey: .moveSkipEngagement)
        moveID = try container.decode(MovementID.self, forKey: .moveID)
        moveForced = try container.decode(Bool.self, forKey: .moveForced)
        moveFromInPlay = try container.decode(Bool.self, forKey: .moveFromInPlay)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(moveSource, forKey: .moveSource)
        try container.encode(moveTarget, forKey: .moveTarget)
        try container.encode(moveDestination, forKey: .moveDestination)
        try container.encode(moveMeans, forKey: .moveMeans)
        try container.encode(moveCancelable, forKey: .moveCancelable)
        try container.encode(movePayAdditionalCosts, forKey: .movePayAdditionalCosts)
        try container.encode(moveAfter, forKey: .moveAfter)
        try container.encode(moveAdditionalEnterCosts, forKey: .moveAdditionalEnterCosts)
        try container.encode(moveSkipEngagement, forKey: .moveSkipEngagement)
        try container.encode(moveID, forKey: .moveID)
        try container.encode(moveForced, forKey: .moveForced)
        try container.encode(moveFromInPlay, forKey: .moveFromInPlay)
    }
}
