extension QuestionPresentation.Ability: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cardCode
        case index
        case type
        case actions
        case canBeCancelled
        case blocksIn
        case nonBlocking
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        let blocksIn = try Self.decodeBlocksIn(from: container)
        let nonBlocking = try Self.decodeNonBlocking(from: container)
        let ability = try Self(
            cardCode: container.decode(String.self, forKey: .cardCode),
            index: container.decode(Int.self, forKey: .index),
            type: container.decode(QuestionPresentation.AbilityType.self, forKey: .type),
            actions: container.decode(
                [QuestionPresentation.Action].self, forKey: .actions
            ),
            canBeCancelled: container.decode(Bool.self, forKey: .canBeCancelled),
            blocksIn: blocksIn,
            nonBlocking: nonBlocking
        )
        try ability.validateDecodedShape(in: container)
        self = ability
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Ability actions must be unique"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardCode, forKey: .cardCode)
        try container.encode(index, forKey: .index)
        try container.encode(type, forKey: .type)
        try container.encode(actions, forKey: .actions)
        try container.encode(canBeCancelled, forKey: .canBeCancelled)
        try container.encodeIfPresent(blocksIn, forKey: .blocksIn)
        try container.encodeIfPresent(nonBlocking, forKey: .nonBlocking)
    }

    var isValidShape: Bool {
        Set(actions).count == actions.count
            && (blocksIn == nil || blocksIn == .null)
            && (nonBlocking == nil || nonBlocking == false)
    }

    private func validateDecodedShape(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard Set(actions).count == actions.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .actions,
                in: container,
                debugDescription: "Ability actions must be unique"
            )
        }
        guard blocksIn == nil || blocksIn == .null else {
            throw DecodingError.dataCorruptedError(
                forKey: .blocksIn,
                in: container,
                debugDescription: "Ability blocksIn must be null when present"
            )
        }
        guard nonBlocking == nil || nonBlocking == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .nonBlocking,
                in: container,
                debugDescription: "Ability nonBlocking must be false when present"
            )
        }
    }

    private static func decodeBlocksIn(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> JSONValue? {
        guard container.contains(.blocksIn) else { return nil }
        return try container.decode(JSONValue.self, forKey: .blocksIn)
    }

    private static func decodeNonBlocking(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Bool? {
        guard container.contains(.nonBlocking) else { return nil }
        return try container.decode(Bool.self, forKey: .nonBlocking)
    }
}
