extension QuestionPresentation.Ability: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cardCode
        case index
        case type
        case actions
        case canBeCancelled
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        let ability = try Self(
            cardCode: container.decode(String.self, forKey: .cardCode),
            index: container.decode(Int.self, forKey: .index),
            type: container.decode(QuestionPresentation.AbilityType.self, forKey: .type),
            actions: container.decode(
                [QuestionPresentation.Action].self, forKey: .actions
            ),
            canBeCancelled: container.decode(Bool.self, forKey: .canBeCancelled)
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
    }

    var isValidShape: Bool {
        Set(actions).count == actions.count
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
    }
}
