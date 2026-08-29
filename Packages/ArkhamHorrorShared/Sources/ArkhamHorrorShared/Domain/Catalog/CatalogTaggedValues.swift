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
    /// A tag not recognized by this client build.
    case unknown(tag: String, contents: JSONValue?)
}

extension CardCost: Equatable, Hashable {}

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
            self = .dynamicCost
        case "DiscardAmountCost":
            self = .discardAmountCost
        case "DeferredCost":
            self = .deferredCost
        case "MaxDynamicCost":
            self = try .maxDynamicCost(container.decode(JSONValue.self, forKey: .contents))
        case "AnyMatchingCardCost":
            self = try .anyMatchingCardCost(container.decode(JSONValue.self, forKey: .contents))
        case "MatchingEnemyFieldCost":
            self = try .matchingEnemyFieldCost(container.decode(JSONValue.self, forKey: .contents))
        default:
            let contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
            self = .unknown(tag: tag, contents: contents)
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
        case let .unknown(tag, contents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(contents, forKey: .contents)
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
    /// A tag not recognized by this client build.
    case unknown(tag: String, contents: JSONValue?)
}

extension GameValue: Equatable, Hashable {}

extension GameValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "Static":
            self = try .staticValue(container.decode(Int.self, forKey: .contents))
        case "PerPlayer":
            self = try .perPlayer(container.decode(Int.self, forKey: .contents))
        case "StaticWithPerPlayer":
            var contents = try container.nestedUnkeyedContainer(forKey: .contents)
            let base = try contents.decode(Int.self)
            let perPlayer = try contents.decode(Int.self)
            guard contents.isAtEnd else {
                let context = DecodingError.Context(
                    codingPath: contents.codingPath,
                    debugDescription: "Expected exactly 2 elements for StaticWithPerPlayer"
                )
                throw DecodingError.dataCorrupted(context)
            }
            self = .staticWithPerPlayer(base, perPlayer)
        case "ByPlayerCount":
            var contents = try container.nestedUnkeyedContainer(forKey: .contents)
            let one = try contents.decode(Int.self)
            let two = try contents.decode(Int.self)
            let three = try contents.decode(Int.self)
            let four = try contents.decode(Int.self)
            guard contents.isAtEnd else {
                let context = DecodingError.Context(
                    codingPath: contents.codingPath,
                    debugDescription: "Expected exactly 4 elements for ByPlayerCount"
                )
                throw DecodingError.dataCorrupted(context)
            }
            self = .byPlayerCount(one, two, three, four)
        case "ValueX":
            self = .valueX
        case "ValueStar":
            self = .valueStar
        case "ValueUnknown":
            self = .valueUnknown
        default:
            let contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
            self = .unknown(tag: tag, contents: contents)
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
        case let .unknown(tag, contents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(contents, forKey: .contents)
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
    /// A tag not recognized by this client build.
    case unknown(tag: String, contents: JSONValue?)
}

extension SkillIcon: Equatable, Hashable {}

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
            self = .wildIcon
        case "WildMinusIcon":
            self = .wildMinusIcon
        default:
            let contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
            self = .unknown(tag: tag, contents: contents)
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
        case let .unknown(tag, contents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(contents, forKey: .contents)
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
