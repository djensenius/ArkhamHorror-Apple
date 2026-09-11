import Foundation

extension BasicChoiceParser {
    /// The exact observed enemy-attack assignment family, not a general
    /// `QuestionWithSource`, `QuestionLabel`, `ComponentLabel`, or damage-assignment
    /// decoder. Each supported family member supplies its complete label, source-order,
    /// amount, and candidate-list contract below.
    static func parseEnemyAttackAssignmentQuestion(
        _ object: [String: JSONValue], rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard let envelope = parseEnemyAttackAssignmentEnvelope(object) else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }

        var boundInvestigatorID: InvestigatorID?
        var choices: [BasicChoice] = []
        for (index, choiceSpec) in envelope.promptSpec.choices.enumerated() {
            guard let parsed = parseEnemyAttackAssignmentChoice(
                envelope.rawChoices[index],
                spec: choiceSpec,
                outerEnemyID: envelope.enemyID
            ) else {
                return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
            }
            if let boundInvestigatorID {
                guard boundInvestigatorID == parsed.investigatorID else {
                    return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
                }
            } else {
                boundInvestigatorID = parsed.investigatorID
            }
            choices.append(BasicChoice(
                index: index,
                rawValue: envelope.rawChoices[index],
                content: parsed.content
            ))
        }

        return .supported(BasicChoiceQuestion(
            kind: .questionWithSource,
            choices: choices,
            story: nil,
            rawValue: rawValue
        ))
    }

    private static func parseEnemyAttackAssignmentEnvelope(
        _ object: [String: JSONValue]
    ) -> EnemyAttackAssignmentEnvelope? {
        guard Set(object.keys) == ["tag", "source", "tooltip", "question"],
              object["tag"] == .string(BasicChoiceQuestionKind.questionWithSource.rawValue),
              let enemyID = enemyAttackSourceID(object["source"]),
              object["tooltip"] == .null,
              case let .object(labelQuestion)? = object["question"],
              Set(labelQuestion.keys) == ["tag", "label", "card", "question"],
              labelQuestion["tag"] == .string("QuestionLabel"),
              case let .string(label)? = labelQuestion["label"],
              labelQuestion["card"] == .null,
              case let .object(chooseOne)? = labelQuestion["question"],
              Set(chooseOne.keys) == ["tag", "choices"],
              chooseOne["tag"] == .string(BasicChoiceQuestionKind.chooseOne.rawValue),
              case let .array(rawChoices)? = chooseOne["choices"],
              let promptSpec = EnemyAttackAssignmentPromptSpec.supported.first(where: {
                  $0.label == label && $0.choices.count == rawChoices.count
              })
        else { return nil }
        return EnemyAttackAssignmentEnvelope(
            enemyID: enemyID,
            rawChoices: rawChoices,
            promptSpec: promptSpec
        )
    }

    private struct ParsedEnemyAttackAssignmentChoice {
        let investigatorID: InvestigatorID
        let content: BasicChoiceContent
    }

    private static func parseEnemyAttackAssignmentChoice(
        _ value: JSONValue,
        spec: EnemyAttackAssignmentChoiceSpec,
        outerEnemyID: EnemyID
    ) -> ParsedEnemyAttackAssignmentChoice? {
        guard case let .object(object) = value,
              Set(object.keys) == ["tag", "component", "messages"],
              object["tag"] == .string("ComponentLabel"),
              case let .object(component)? = object["component"],
              Set(component.keys) == ["tag", "investigatorId", "tokenType"],
              component["tag"] == .string("InvestigatorComponent"),
              case let .string(rawInvestigatorID)? = component["investigatorId"],
              let investigatorCode = strictCardCode(rawInvestigatorID),
              component["tokenType"] == .string(spec.kind.tokenType),
              case let .array(messages)? = object["messages"],
              messages.count == 2
        else { return nil }

        let investigatorID = InvestigatorID(investigatorCode)
        guard damageMessage(
            messages[0],
            investigatorID: investigatorID,
            enemyID: outerEnemyID,
            amounts: spec.direct
        ),
            assignmentContinuation(
                messages[1],
                investigatorID: investigatorID,
                enemyID: outerEnemyID,
                spec: spec
            )
        else { return nil }

        return ParsedEnemyAttackAssignmentChoice(
            investigatorID: investigatorID,
            content: .assignEnemyAttackDamage(EnemyAttackDamageAssignment(
                kind: spec.kind,
                enemyID: outerEnemyID,
                investigatorID: investigatorID,
                messages: messages
            ))
        )
    }

    private static func damageMessage(
        _ value: JSONValue,
        investigatorID: InvestigatorID,
        enemyID: EnemyID,
        amounts: EnemyAttackAssignmentAmounts
    ) -> Bool {
        guard let contents = investigatorMessageContents(value, tag: "InvestigatorDamage_"),
              contents.count == 4,
              contents[0] == .string(investigatorID.rawValue.rawValue),
              enemyAttackSourceID(contents[1]) == enemyID,
              canonicalInteger(contents[2], equals: amounts.damage),
              canonicalInteger(contents[3], equals: amounts.horror)
        else { return false }
        return true
    }

    private static func assignmentContinuation(
        _ value: JSONValue,
        investigatorID: InvestigatorID,
        enemyID: EnemyID,
        spec: EnemyAttackAssignmentChoiceSpec
    ) -> Bool {
        guard let contents = investigatorMessageContents(
            value, tag: "InvestigatorDoAssignDamage_"
        ),
            contents.count == 8,
            contents[0] == .string(investigatorID.rawValue.rawValue),
            enemyAttackSourceID(contents[1]) == enemyID,
            contents[2] == .object(["tag": .string("DamageAny")]),
            contents[3] == .object(["tag": .string("AnyAsset")]),
            canonicalInteger(contents[4], equals: spec.remaining.damage),
            canonicalInteger(contents[5], equals: spec.remaining.horror),
            candidateList(
                contents[6], expected: spec.damageCandidates, investigatorID: investigatorID
            ),
            candidateList(
                contents[7], expected: spec.horrorCandidates, investigatorID: investigatorID
            )
        else { return false }
        return true
    }

    private static func investigatorMessageContents(
        _ value: JSONValue,
        tag: String
    ) -> [JSONValue]? {
        guard case let .object(message) = value,
              Set(message.keys) == ["tag", "contents"],
              message["tag"] == .string("InvestigatorMessage"),
              case let .object(constructor)? = message["contents"],
              Set(constructor.keys) == ["tag", "contents"],
              constructor["tag"] == .string(tag),
              case let .array(contents)? = constructor["contents"]
        else { return nil }
        return contents
    }

    private static func candidateList(
        _ value: JSONValue,
        expected: EnemyAttackAssignmentCandidateSet,
        investigatorID: InvestigatorID
    ) -> Bool {
        guard case let .array(candidates) = value else { return false }
        if case .empty = expected {
            return candidates.isEmpty
        }
        guard candidates.count == 1,
              case let .object(target) = candidates[0],
              Set(target.keys) == ["tag", "contents"],
              target["tag"] == .string("InvestigatorTarget"),
              target["contents"] == .string(investigatorID.rawValue.rawValue)
        else { return false }
        return true
    }

    private static func enemyAttackSourceID(_ value: JSONValue?) -> EnemyID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("EnemyAttackSource"),
              case let .string(rawEnemyID)? = source["contents"]
        else { return nil }
        return EnemyID(codingKey: AnyCodingKey(stringValue: rawEnemyID))
    }

    private static func canonicalInteger(
        _ value: JSONValue,
        equals expected: Int64
    ) -> Bool {
        guard isCanonicalInteger(value),
              case let .number(number) = value
        else { return false }
        return number.rawToken == String(expected)
    }
}

private struct EnemyAttackAssignmentEnvelope {
    let enemyID: EnemyID
    let rawChoices: [JSONValue]
    let promptSpec: EnemyAttackAssignmentPromptSpec
}

private struct EnemyAttackAssignmentPromptSpec {
    let label: String
    let choices: [EnemyAttackAssignmentChoiceSpec]

    static let supported = [
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 damage and 1 horror",
            choices: [
                EnemyAttackAssignmentChoiceSpec(
                    kind: .damage,
                    direct: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    damageCandidates: .investigator,
                    horrorCandidates: .empty
                ),
                EnemyAttackAssignmentChoiceSpec(
                    kind: .horror,
                    direct: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    remaining: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    damageCandidates: .empty,
                    horrorCandidates: .investigator
                ),
            ]
        ),
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 horror",
            choices: [
                EnemyAttackAssignmentChoiceSpec(
                    kind: .horror,
                    direct: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 0),
                    damageCandidates: .investigator,
                    horrorCandidates: .investigator
                ),
            ]
        ),
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 damage",
            choices: [
                EnemyAttackAssignmentChoiceSpec(
                    kind: .damage,
                    direct: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 0),
                    damageCandidates: .investigator,
                    horrorCandidates: .investigator
                ),
            ]
        ),
    ]
}

private struct EnemyAttackAssignmentChoiceSpec {
    let kind: EnemyAttackAssignmentKind
    let direct: EnemyAttackAssignmentAmounts
    let remaining: EnemyAttackAssignmentAmounts
    let damageCandidates: EnemyAttackAssignmentCandidateSet
    let horrorCandidates: EnemyAttackAssignmentCandidateSet
}

private struct EnemyAttackAssignmentAmounts {
    let damage: Int64
    let horror: Int64
}

private enum EnemyAttackAssignmentCandidateSet {
    case empty
    case investigator
}

private extension EnemyAttackAssignmentKind {
    var tokenType: String {
        switch self {
        case .damage: "DamageToken"
        case .horror: "HorrorToken"
        }
    }
}
