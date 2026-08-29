/// `CardDef.cost`: how many resources a card costs to play.
///
/// Tags without a `contents` key (`DynamicCost`, `DiscardAmountCost`, `DeferredCost`) are
/// computed at play time by other rules text, not by a static number here.
enum CardCost: Sendable {
    /// A fixed resource cost.
    case staticCost(Int)
    /// Cost computed dynamically by the card's own rules text.
    case dynamicCost
    /// Cost equal to the number of cards discarded to pay it.
    case discardAmountCost
    /// Cost deferred to a later effect.
    case deferredCost
    /// An upper-bounded dynamic cost; contents are schema-unconstrained.
    case maxDynamicCost(JSONValue)
    /// A cost keyed to any matching card; contents are schema-unconstrained.
    case anyMatchingCardCost(JSONValue)
    /// A cost keyed to a matching enemy field; contents are schema-unconstrained.
    case matchingEnemyFieldCost(JSONValue)
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// (tag, contents presence/absence/null-ness, and any additive keys) so nothing is
    /// lost; never encodable, since resubmitting data this client doesn't understand is
    /// unsafe by construction.
    case unknown(tag: String, rawObject: JSONValue)
}

extension CardCost: Equatable, Hashable {}

/// Thrown when encoding a ``CardCost`` whose tag this client build never recognized.
enum CardCostError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

extension CardCost: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "StaticCost":
            self = try .staticCost(container.decode(Int.self, forKey: .contents))
        case "DynamicCost":
            try rejectPresentContents(
                container,
                contentsKey: .contents,
                tag: tag,
                codingPath: decoder.codingPath
            )
            self = .dynamicCost
        case "DiscardAmountCost":
            try rejectPresentContents(
                container,
                contentsKey: .contents,
                tag: tag,
                codingPath: decoder.codingPath
            )
            self = .discardAmountCost
        case "DeferredCost":
            try rejectPresentContents(
                container,
                contentsKey: .contents,
                tag: tag,
                codingPath: decoder.codingPath
            )
            self = .deferredCost
        case "MaxDynamicCost":
            self = try .maxDynamicCost(container.decode(JSONValue.self, forKey: .contents))
        case "AnyMatchingCardCost":
            self = try .anyMatchingCardCost(container.decode(JSONValue.self, forKey: .contents))
        case "MatchingEnemyFieldCost":
            self = try .matchingEnemyFieldCost(container.decode(JSONValue.self, forKey: .contents))
        default:
            self = try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .staticCost(value):
            try container.encode("StaticCost", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case .dynamicCost:
            try container.encode("DynamicCost", forKey: .tag)
        case .discardAmountCost:
            try container.encode("DiscardAmountCost", forKey: .tag)
        case .deferredCost:
            try container.encode("DeferredCost", forKey: .tag)
        case let .maxDynamicCost(contents):
            try container.encode("MaxDynamicCost", forKey: .tag)
            try container.encode(contents, forKey: .contents)
        case let .anyMatchingCardCost(contents):
            try container.encode("AnyMatchingCardCost", forKey: .tag)
            try container.encode(contents, forKey: .contents)
        case let .matchingEnemyFieldCost(contents):
            try container.encode("MatchingEnemyFieldCost", forKey: .tag)
            try container.encode(contents, forKey: .contents)
        case let .unknown(tag, _):
            throw CardCostError.cannotEncodeUnknownTag(tag)
        }
    }
}

/// `CardDef.health`/`.fight`/`.evade`/`.healthDamage`/`.sanityDamage`: a stat that may be
/// fixed, scale with player count, or resolve dynamically at play time.
enum GameValue: Sendable {
    /// A fixed value.
    case staticValue(Int)
    /// A value scaling per investigator.
    case perPlayer(Int)
    /// A base value plus a per-player increment: `(base, perPlayer)`.
    case staticWithPerPlayer(Int, Int)
    /// One value per player count from 1 to 4 players: `(one, two, three, four)`.
    case byPlayerCount(Int, Int, Int, Int)
    /// Resolved by an "X" printed on the card.
    case valueX
    /// Resolved by a star-footnote printed on the card.
    case valueStar
    /// Not revealed until play.
    case valueUnknown
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// so nothing is lost; never encodable.
    case unknown(tag: String, rawObject: JSONValue)
}

extension GameValue: Equatable, Hashable {}

/// Thrown when encoding a ``GameValue`` whose tag this client build never recognized.
enum GameValueError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

extension GameValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    /// Decodes exactly `count` `Int`s from `contents`, throwing if more or fewer than
    /// `count` elements are present. Shared by `StaticWithPerPlayer`'s 2-element array and
    /// `ByPlayerCount`'s 4-element array.
    private static func decodeFixedIntArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        count: Int
    ) throws -> [Int] {
        var contents = try container.nestedUnkeyedContainer(forKey: .contents)
        var values: [Int] = []
        while !contents.isAtEnd {
            try values.append(contents.decode(Int.self))
        }
        guard values.count == count else {
            let context = DecodingError.Context(
                codingPath: contents.codingPath,
                debugDescription: "Expected exactly \(count) elements, found \(values.count)"
            )
            throw DecodingError.dataCorrupted(context)
        }
        return values
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
        case "Static":
            self = try .staticValue(container.decode(Int.self, forKey: .contents))
        case "PerPlayer":
            self = try .perPlayer(container.decode(Int.self, forKey: .contents))
        case "StaticWithPerPlayer":
            let values = try Self.decodeFixedIntArray(from: container, count: 2)
            self = .staticWithPerPlayer(values[0], values[1])
        case "ByPlayerCount":
            let values = try Self.decodeFixedIntArray(from: container, count: 4)
            self = .byPlayerCount(values[0], values[1], values[2], values[3])
        case "ValueX":
            try nullaryCase()
            self = .valueX
        case "ValueStar":
            try nullaryCase()
            self = .valueStar
        case "ValueUnknown":
            try nullaryCase()
            self = .valueUnknown
        default:
            self = try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .staticValue(value):
            try container.encode("Static", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case let .perPlayer(value):
            try container.encode("PerPlayer", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case let .staticWithPerPlayer(base, perPlayer):
            try container.encode("StaticWithPerPlayer", forKey: .tag)
            var contents = container.nestedUnkeyedContainer(forKey: .contents)
            try contents.encode(base)
            try contents.encode(perPlayer)
        case let .byPlayerCount(one, two, three, four):
            try container.encode("ByPlayerCount", forKey: .tag)
            var contents = container.nestedUnkeyedContainer(forKey: .contents)
            try contents.encode(one)
            try contents.encode(two)
            try contents.encode(three)
            try contents.encode(four)
        case .valueX:
            try container.encode("ValueX", forKey: .tag)
        case .valueStar:
            try container.encode("ValueStar", forKey: .tag)
        case .valueUnknown:
            try container.encode("ValueUnknown", forKey: .tag)
        case let .unknown(tag, _):
            throw GameValueError.cannotEncodeUnknownTag(tag)
        }
    }
}

/// `CardDef.skills`: one skill-test icon printed on a card.
enum SkillIcon: Sendable {
    /// A specific skill icon.
    case skill(Skill)
    /// A wild icon, usable for any skill.
    case wildIcon
    /// A wild-minus icon, usable for any skill but reducing the skill value.
    case wildMinusIcon
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// so nothing is lost; never encodable.
    case unknown(tag: String, rawObject: JSONValue)
}

extension SkillIcon: Equatable, Hashable {}

/// Thrown when encoding a ``SkillIcon`` whose tag this client build never recognized.
enum SkillIconError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

extension SkillIcon: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "SkillIcon":
            self = try .skill(container.decode(Skill.self, forKey: .contents))
        case "WildIcon":
            try rejectPresentContents(
                container,
                contentsKey: .contents,
                tag: tag,
                codingPath: decoder.codingPath
            )
            self = .wildIcon
        case "WildMinusIcon":
            try rejectPresentContents(
                container,
                contentsKey: .contents,
                tag: tag,
                codingPath: decoder.codingPath
            )
            self = .wildMinusIcon
        default:
            self = try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .skill(skill):
            try container.encode("SkillIcon", forKey: .tag)
            try container.encode(skill, forKey: .contents)
        case .wildIcon:
            try container.encode("WildIcon", forKey: .tag)
        case .wildMinusIcon:
            try container.encode("WildMinusIcon", forKey: .tag)
        case let .unknown(tag, _):
            throw SkillIconError.cannotEncodeUnknownTag(tag)
        }
    }
}

/// One entry of `CardDef.bondedWith`: a bonded card and how many copies are granted,
/// encoded on the wire as a 2-element `[count, cardCode]` array.
struct BondedCardEntry: Sendable {
    let count: Int
    let cardCode: CardCode
}

extension BondedCardEntry: Equatable, Hashable {}

extension BondedCardEntry: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        count = try container.decode(Int.self)
        cardCode = try container.decode(CardCode.self)
        guard container.isAtEnd else {
            let context = DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected exactly 2 elements for BondedCardEntry"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(count)
        try container.encode(cardCode)
    }
}
