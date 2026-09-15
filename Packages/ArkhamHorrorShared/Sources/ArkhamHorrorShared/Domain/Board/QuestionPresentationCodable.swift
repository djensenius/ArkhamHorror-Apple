import Foundation

extension QuestionPresentation: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case questionVersion
        case questionKind
        case choiceCount
        case choices
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported question presentation protocol \(protocolVersion)"
            )
        }
        let questionVersion = try container.decode(Int.self, forKey: .questionVersion)
        guard questionVersion >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .questionVersion,
                in: container,
                debugDescription: "questionVersion must be non-negative"
            )
        }
        let questionKind = try container.decode(Kind.self, forKey: .questionKind)
        let choiceCount = try container.decode(Int.self, forKey: .choiceCount)
        guard choiceCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .choiceCount,
                in: container,
                debugDescription: "choiceCount must be non-negative"
            )
        }
        let choices = try container.decode([Choice].self, forKey: .choices)
        try Self.validateSourceIndices(
            choices,
            choiceCount: choiceCount,
            in: container
        )
        let presentation = Self(
            protocolVersion: protocolVersion,
            questionVersion: questionVersion,
            questionKind: questionKind,
            choiceCount: choiceCount,
            choices: choices
        )
        try Self.validateSupportedAdvanceActSemantics(
            presentation,
            in: container
        )
        self = presentation
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid question presentation"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(questionVersion, forKey: .questionVersion)
        try container.encode(questionKind, forKey: .questionKind)
        try container.encode(choiceCount, forKey: .choiceCount)
        try container.encode(choices, forKey: .choices)
    }

    private static func validateSourceIndices(
        _ choices: [Choice],
        choiceCount: Int,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        var sourceIndices = Set<Int>()
        for choice in choices {
            guard choice.sourceIndex < choiceCount else {
                throw DecodingError.dataCorruptedError(
                    forKey: .choices,
                    in: container,
                    debugDescription: "Choice sourceIndex \(choice.sourceIndex) is out of bounds"
                )
            }
            guard sourceIndices.insert(choice.sourceIndex).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .choices,
                    in: container,
                    debugDescription: "Duplicate choice sourceIndex \(choice.sourceIndex)"
                )
            }
        }
    }

    private static func validateSupportedAdvanceActSemantics(
        _ presentation: QuestionPresentation,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard presentation.hasSupportedAdvanceActSemantics else {
            throw DecodingError.dataCorruptedError(
                forKey: .choices,
                in: container,
                debugDescription: "Unsupported advanceAct semantic descriptor"
            )
        }
    }

    private var isValidShape: Bool {
        guard protocolVersion == Self.supportedProtocolVersion,
              questionVersion >= 0,
              choiceCount >= 0,
              choices.allSatisfy(\.isValidShape),
              hasSupportedAdvanceActSemantics
        else { return false }
        let indices = choices.map(\.sourceIndex)
        return indices.allSatisfy { $0 < choiceCount } && Set(indices).count == indices.count
    }

    private var hasSupportedAdvanceActSemantics: Bool {
        let advanceActChoices = choices.filter { $0.kind == .advanceAct }
        switch (questionVersion, questionKind, choiceCount) {
        case (34, .playerWindowChooseOne, 13):
            return advanceActChoices == [.gatheringActObjective]
        case (35, .chooseOne, 1):
            return choices == [.gatheringActAdvance]
        default:
            return advanceActChoices.isEmpty
        }
    }
}

extension QuestionPresentation.Choice: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceIndex
        case kind
        case actorID = "actorId"
        case entity
        case label
        case ability
        case cost
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        let choice = try Self(
            sourceIndex: container.decode(Int.self, forKey: .sourceIndex),
            kind: container.decode(QuestionPresentation.ChoiceKind.self, forKey: .kind),
            actorID: container.decodePresentIfContained(String.self, forKey: .actorID),
            entity: container.decodePresentIfContained(
                QuestionPresentation.Entity.self, forKey: .entity
            ),
            label: container.decodePresentIfContained(
                QuestionPresentation.Label.self, forKey: .label
            ),
            ability: container.decodePresentIfContained(
                QuestionPresentation.Ability.self, forKey: .ability
            ),
            cost: container.decodePresentIfContained(
                QuestionPresentation.Cost.self, forKey: .cost
            )
        )
        guard choice.isValidShape else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid semantic choice descriptor"
                )
            )
        }
        self = choice
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid semantic choice descriptor"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceIndex, forKey: .sourceIndex)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(actorID, forKey: .actorID)
        try container.encodeIfPresent(entity, forKey: .entity)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(ability, forKey: .ability)
        try container.encodeIfPresent(cost, forKey: .cost)
    }

    fileprivate var isValidShape: Bool {
        guard sourceIndex >= 0,
              ability?.isValidShape != false,
              cost?.isValidShape != false
        else { return false }
        switch kind {
        case .drawCard, .endTurn, .gainResource, .skipTriggers, .startSkillTest:
            return actorID != nil
        case .localizedLabel:
            return label != nil
        case .chooseTarget:
            return entity != nil
        case .useAbility:
            return actorID != nil && ability != nil && cost != nil
        case .advanceAct:
            return self == Self.gatheringActObjective ||
                self == Self.gatheringActAdvance
        case .advanceAgenda:
            return entity?.kind == .agenda && authorityFieldsAreAllPresentOrAbsent
        case .applySkillTestResults, .engage, .evade, .fight, .investigate:
            return true
        }
    }

    private var authorityFieldsAreAllPresentOrAbsent: Bool {
        let allPresent = actorID != nil && ability != nil && cost != nil
        let allAbsent = actorID == nil && ability == nil && cost == nil
        return allPresent || allAbsent
    }

    fileprivate static let gatheringActObjective = Self(
        sourceIndex: 12,
        kind: .advanceAct,
        actorID: "c01001",
        entity: .init(kind: .act, id: "c01108"),
        label: nil,
        ability: .init(
            cardCode: "c01108",
            index: 999,
            type: .objective,
            actions: [],
            canBeCancelled: true
        ),
        cost: .groupClue(amount: .perPlayer(2), scope: .anywhere)
    )

    fileprivate static let gatheringActAdvance = Self(
        sourceIndex: 0,
        kind: .advanceAct,
        actorID: nil,
        entity: .init(kind: .act, id: "c01108"),
        label: nil,
        ability: nil,
        cost: nil
    )
}

extension QuestionPresentation.Entity: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case id
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            kind: container.decode(QuestionPresentation.EntityKind.self, forKey: .kind),
            id: container.decode(String.self, forKey: .id)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
    }
}

extension QuestionPresentation.Label: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case text
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            kind: container.decode(QuestionPresentation.LabelKind.self, forKey: .kind),
            text: container.decode(String.self, forKey: .text)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
    }
}

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
        guard ability.isValidShape else {
            throw DecodingError.dataCorruptedError(
                forKey: .actions,
                in: container,
                debugDescription: "Ability actions must be unique"
            )
        }
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

    fileprivate var isValidShape: Bool {
        Set(actions).count == actions.count
    }
}

func questionPresentationClosedContainer<Key: CodingKey>(
    _ decoder: any Decoder,
    keyedBy type: Key.Type,
    allowing allowedKeys: [Key]
) throws -> KeyedDecodingContainer<Key> {
    let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowed = Set(allowedKeys.map(\.stringValue))
    let unknown = Set(rawContainer.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected keys: \(unknown.sorted().joined(separator: ", "))"
            )
        )
    }
    return try decoder.container(keyedBy: type)
}

private extension KeyedDecodingContainer {
    func decodePresentIfContained<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}
