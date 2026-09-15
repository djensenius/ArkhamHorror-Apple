import Foundation

extension QuestionPresentation.Cost: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case amount
        case scope
        case costs
    }

    private enum Kind: String, Codable {
        case free
        case action
        case resource
        case clue
        case groupClue
        case groupResource
        case all
        case choice
        case other

        var allowedKeys: [CodingKeys] {
            switch self {
            case .free, .other:
                [.kind]
            case .action, .resource, .clue:
                [.kind, .amount]
            case .groupClue, .groupResource:
                [.kind, .amount, .scope]
            case .all, .choice:
                [.kind, .costs]
            }
        }
    }

    init(from decoder: any Decoder) throws {
        let kindContainer = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try kindContainer.decode(Kind.self, forKey: .kind)
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: kind.allowedKeys
        )
        self = try Self.decodeCost(kind, from: container)
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid presentation cost")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .free:
            try container.encode(Kind.free, forKey: .kind)
        case let .action(amount):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(amount, forKey: .amount)
        case let .resource(amount):
            try container.encode(Kind.resource, forKey: .kind)
            try container.encode(amount, forKey: .amount)
        case let .clue(amount):
            try container.encode(Kind.clue, forKey: .kind)
            try container.encode(amount, forKey: .amount)
        case let .groupClue(amount, scope):
            try container.encode(Kind.groupClue, forKey: .kind)
            try container.encode(amount, forKey: .amount)
            try container.encode(scope, forKey: .scope)
        case let .groupResource(amount, scope):
            try container.encode(Kind.groupResource, forKey: .kind)
            try container.encode(amount, forKey: .amount)
            try container.encode(scope, forKey: .scope)
        case let .all(costs):
            try container.encode(Kind.all, forKey: .kind)
            try container.encode(costs, forKey: .costs)
        case let .choice(costs):
            try container.encode(Kind.choice, forKey: .kind)
            try container.encode(costs, forKey: .costs)
        case .other:
            try container.encode(Kind.other, forKey: .kind)
        }
    }

    var isValidShape: Bool {
        switch self {
        case .free, .other:
            true
        case let .action(amount), let .resource(amount):
            amount >= 0
        case let .clue(amount):
            amount.isValidShape
        case let .groupClue(amount, _), let .groupResource(amount, _):
            amount.isValidShape
        case let .all(costs), let .choice(costs):
            !costs.isEmpty && costs.allSatisfy(\.isValidShape)
        }
    }

    private static func decodeCost(
        _ kind: Kind,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        switch kind {
        case .free:
            return .free
        case .other:
            return .other
        case .action, .resource:
            let amount = try nonNegativeAmount(from: container)
            return kind == .action ? .action(amount) : .resource(amount)
        case .clue:
            return try .clue(
                container.decode(QuestionPresentation.Amount.self, forKey: .amount)
            )
        case .groupClue, .groupResource:
            let amount = try container.decode(
                QuestionPresentation.Amount.self,
                forKey: .amount
            )
            let scope = try container.decode(
                QuestionPresentation.Scope.self,
                forKey: .scope
            )
            return kind == .groupClue
                ? .groupClue(amount: amount, scope: scope)
                : .groupResource(amount: amount, scope: scope)
        case .all, .choice:
            return try decodeComposite(kind, from: container)
        }
    }

    private static func decodeComposite(
        _ kind: Kind,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        let costs = try container.decode([Self].self, forKey: .costs)
        guard !costs.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .costs,
                in: container,
                debugDescription: "Composite presentation costs must not be empty"
            )
        }
        return kind == .all ? .all(costs) : .choice(costs)
    }

    private static func nonNegativeAmount(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int {
        let amount = try container.decode(Int.self, forKey: .amount)
        guard amount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Presentation cost amount must be non-negative"
            )
        }
        return amount
    }
}

extension QuestionPresentation.Amount: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case fixed
        case perPlayer
        case values
    }

    private enum Kind: String, Codable {
        case fixed
        case perPlayer
        case fixedPlusPerPlayer
        case byPlayerCount
        case variable = "x"
        case star
        case unknown

        var allowedKeys: [CodingKeys] {
            switch self {
            case .fixed, .perPlayer:
                [.kind, .value]
            case .fixedPlusPerPlayer:
                [.kind, .fixed, .perPlayer]
            case .byPlayerCount:
                [.kind, .values]
            case .variable, .star, .unknown:
                [.kind]
            }
        }
    }

    init(from decoder: any Decoder) throws {
        let kindContainer = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try kindContainer.decode(Kind.self, forKey: .kind)
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: kind.allowedKeys
        )
        self = try Self.decodeAmount(kind, from: container, codingPath: decoder.codingPath)
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid presentation amount"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fixed(value):
            try container.encode(Kind.fixed, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .perPlayer(value):
            try container.encode(Kind.perPlayer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .fixedPlusPerPlayer(fixed, perPlayer):
            try container.encode(Kind.fixedPlusPerPlayer, forKey: .kind)
            try container.encode(fixed, forKey: .fixed)
            try container.encode(perPlayer, forKey: .perPlayer)
        case let .byPlayerCount(values):
            try container.encode(Kind.byPlayerCount, forKey: .kind)
            try container.encode(values, forKey: .values)
        case .variable:
            try container.encode(Kind.variable, forKey: .kind)
        case .star:
            try container.encode(Kind.star, forKey: .kind)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }

    fileprivate var isValidShape: Bool {
        switch self {
        case let .fixed(value), let .perPlayer(value):
            value >= 0
        case let .fixedPlusPerPlayer(fixed, perPlayer):
            fixed >= 0 && perPlayer >= 0
        case let .byPlayerCount(values):
            values.count == 4 && values.allSatisfy { $0 >= 0 }
        case .variable, .star, .unknown:
            true
        }
    }

    private static func decodeAmount(
        _ kind: Kind,
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [any CodingKey]
    ) throws -> Self {
        switch kind {
        case .fixed, .perPlayer:
            let value = try nonNegativeValue(from: container)
            return kind == .fixed ? .fixed(value) : .perPlayer(value)
        case .fixedPlusPerPlayer:
            return try fixedPlusPerPlayer(from: container, codingPath: codingPath)
        case .byPlayerCount:
            return try byPlayerCount(from: container)
        case .variable:
            return .variable
        case .star:
            return .star
        case .unknown:
            return .unknown
        }
    }

    private static func nonNegativeValue(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int {
        let value = try container.decode(Int.self, forKey: .value)
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Presentation amount must be non-negative"
            )
        }
        return value
    }

    private static func fixedPlusPerPlayer(
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [any CodingKey]
    ) throws -> Self {
        let fixed = try container.decode(Int.self, forKey: .fixed)
        let perPlayer = try container.decode(Int.self, forKey: .perPlayer)
        guard fixed >= 0, perPlayer >= 0 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath,
                    debugDescription: "Presentation amounts must be non-negative"
                )
            )
        }
        return .fixedPlusPerPlayer(fixed: fixed, perPlayer: perPlayer)
    }

    private static func byPlayerCount(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        let values = try container.decode([Int].self, forKey: .values)
        guard values.count == 4, values.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .values,
                in: container,
                debugDescription: "byPlayerCount requires four non-negative values"
            )
        }
        return .byPlayerCount(values)
    }
}

extension QuestionPresentation.Scope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case locationID = "locationId"
    }

    private enum Kind: String, Codable {
        case anywhere
        case sameLocation
        case location
        case other
    }

    init(from decoder: any Decoder) throws {
        let kindContainer = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try kindContainer.decode(Kind.self, forKey: .kind)
        let allowedKeys: [CodingKeys] = kind == .location
            ? [.kind, .locationID]
            : [.kind]
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: allowedKeys
        )
        switch kind {
        case .anywhere:
            self = .anywhere
        case .sameLocation:
            self = .sameLocation
        case .location:
            self = try .location(container.decode(String.self, forKey: .locationID))
        case .other:
            self = .other
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anywhere:
            try container.encode(Kind.anywhere, forKey: .kind)
        case .sameLocation:
            try container.encode(Kind.sameLocation, forKey: .kind)
        case let .location(locationID):
            try container.encode(Kind.location, forKey: .kind)
            try container.encode(locationID, forKey: .locationID)
        case .other:
            try container.encode(Kind.other, forKey: .kind)
        }
    }
}
