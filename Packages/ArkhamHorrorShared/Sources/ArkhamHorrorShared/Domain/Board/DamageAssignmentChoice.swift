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
              case let .array(messages)? = object["messages"],
              messages.count == 2
        else { return nil }

        switch component["tag"] {
        case .string("InvestigatorComponent"):
            return parseInvestigatorAssignmentChoice(
                component: component,
                messages: messages,
                spec: spec,
                outerEnemyID: outerEnemyID
            )
        case .string("AssetComponent"):
            return parseAssetAssignmentChoice(
                component: component,
                messages: messages,
                spec: spec,
                outerEnemyID: outerEnemyID
            )
        default:
            return nil
        }
    }

    private static func parseInvestigatorAssignmentChoice(
        component: [String: JSONValue],
        messages: [JSONValue],
        spec: EnemyAttackAssignmentChoiceSpec,
        outerEnemyID: EnemyID
    ) -> ParsedEnemyAttackAssignmentChoice? {
        guard Set(component.keys) == ["tag", "investigatorId", "tokenType"],
              case let .string(rawInvestigatorID)? = component["investigatorId"],
              let investigatorCode = strictCardCode(rawInvestigatorID),
              component["tokenType"] == .string(spec.kind.tokenType)
        else { return nil }

        let investigatorID = InvestigatorID(investigatorCode)
        let target = EnemyAttackDamageAssignmentTarget.investigator(investigatorID)
        guard damageMessage(
            messages[0],
            investigatorID: investigatorID,
            enemyID: outerEnemyID,
            amounts: spec.direct
        ),
            assignmentContinuation(
                messages[1],
                expectedInvestigatorID: investigatorID,
                target: target,
                enemyID: outerEnemyID,
                spec: spec
            ) == investigatorID
        else { return nil }

        return parsedChoice(
            investigatorID: investigatorID,
            target: target,
            messages: messages,
            spec: spec,
            outerEnemyID: outerEnemyID
        )
    }

    private static func parseAssetAssignmentChoice(
        component: [String: JSONValue],
        messages: [JSONValue],
        spec: EnemyAttackAssignmentChoiceSpec,
        outerEnemyID: EnemyID
    ) -> ParsedEnemyAttackAssignmentChoice? {
        guard Set(component.keys) == ["tag", "assetId", "tokenType"],
              case let .string(rawAssetID)? = component["assetId"],
              let assetID = canonicalAssetID(rawAssetID),
              component["tokenType"] == .string(spec.kind.tokenType)
        else { return nil }

        let target = EnemyAttackDamageAssignmentTarget.asset(assetID)
        guard assetDamageMessage(
            messages[0],
            assetID: assetID,
            enemyID: outerEnemyID,
            amounts: spec.direct
        ),
            let investigatorID = assignmentContinuation(
                messages[1],
                expectedInvestigatorID: nil,
                target: target,
                enemyID: outerEnemyID,
                spec: spec
            )
        else { return nil }

        return parsedChoice(
            investigatorID: investigatorID,
            target: target,
            messages: messages,
            spec: spec,
            outerEnemyID: outerEnemyID
        )
    }

    private static func parsedChoice(
        investigatorID: InvestigatorID,
        target: EnemyAttackDamageAssignmentTarget,
        messages: [JSONValue],
        spec: EnemyAttackAssignmentChoiceSpec,
        outerEnemyID: EnemyID
    ) -> ParsedEnemyAttackAssignmentChoice {
        ParsedEnemyAttackAssignmentChoice(
            investigatorID: investigatorID,
            content: .assignEnemyAttackDamage(EnemyAttackDamageAssignment(
                kind: spec.kind,
                enemyID: outerEnemyID,
                investigatorID: investigatorID,
                target: target,
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

    private static func assetDamageMessage(
        _ value: JSONValue,
        assetID: AssetID,
        enemyID: EnemyID,
        amounts: EnemyAttackAssignmentAmounts
    ) -> Bool {
        guard case let .object(message) = value,
              Set(message.keys) == ["tag", "contents"],
              message["tag"] == .string("AssignAssetDamageDeferred"),
              case let .array(contents)? = message["contents"],
              contents.count == 4,
              contents[0] == .string(assetID.codingKey.stringValue),
              enemyAttackSourceID(contents[1]) == enemyID,
              canonicalInteger(contents[2], equals: amounts.damage),
              canonicalInteger(contents[3], equals: amounts.horror)
        else { return false }
        return true
    }

    private static func assignmentContinuation(
        _ value: JSONValue,
        expectedInvestigatorID: InvestigatorID?,
        target: EnemyAttackDamageAssignmentTarget,
        enemyID: EnemyID,
        spec: EnemyAttackAssignmentChoiceSpec
    ) -> InvestigatorID? {
        guard let contents = investigatorMessageContents(
            value, tag: "InvestigatorDoAssignDamage_"
        ),
            contents.count == 8,
            case let .string(rawInvestigatorID) = contents[0],
            let investigatorCode = strictCardCode(rawInvestigatorID),
            enemyAttackSourceID(contents[1]) == enemyID,
            contents[2] == .object(["tag": .string("DamageAny")]),
            contents[3] == .object(["tag": .string("AnyAsset")]),
            canonicalInteger(contents[4], equals: spec.remaining.damage),
            canonicalInteger(contents[5], equals: spec.remaining.horror),
            candidateList(
                contents[6],
                expected: spec.damageCandidates,
                target: target,
                remainingAmount: spec.remaining.damage
            ),
            candidateList(
                contents[7],
                expected: spec.horrorCandidates,
                target: target,
                remainingAmount: spec.remaining.horror
            )
        else { return nil }
        let investigatorID = InvestigatorID(investigatorCode)
        guard expectedInvestigatorID == nil || expectedInvestigatorID == investigatorID else {
            return nil
        }
        return investigatorID
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
        target: EnemyAttackDamageAssignmentTarget,
        remainingAmount: Int64
    ) -> Bool {
        guard case let .array(candidates) = value else { return false }
        switch expected {
        case .empty:
            return candidates.isEmpty
        case .target:
            return candidates == [candidateTarget(target)]
        case .targetOrEmptyWhenRemainingZero:
            if candidates == [candidateTarget(target)] {
                return true
            }
            return remainingAmount == 0 && candidates.isEmpty
        }
    }

    private static func candidateTarget(_ target: EnemyAttackDamageAssignmentTarget) -> JSONValue {
        switch target {
        case let .investigator(investigatorID):
            .object([
                "tag": .string("InvestigatorTarget"),
                "contents": .string(investigatorID.rawValue.rawValue),
            ])
        case let .asset(assetID):
            .object([
                "tag": .string("AssetTarget"),
                "contents": .string(assetID.codingKey.stringValue),
            ])
        }
    }

    private static func enemyAttackSourceID(_ value: JSONValue?) -> EnemyID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("EnemyAttackSource"),
              case let .string(rawEnemyID)? = source["contents"]
        else { return nil }
        return EnemyID(codingKey: AnyCodingKey(stringValue: rawEnemyID))
    }

    private static func canonicalAssetID(_ rawAssetID: String) -> AssetID? {
        AssetID(codingKey: AnyCodingKey(stringValue: rawAssetID))
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
                    damageCandidates: .target,
                    horrorCandidates: .empty
                ),
                EnemyAttackAssignmentChoiceSpec(
                    kind: .horror,
                    direct: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    remaining: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    damageCandidates: .empty,
                    horrorCandidates: .target
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
                    damageCandidates: .targetOrEmptyWhenRemainingZero,
                    horrorCandidates: .target
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
                    damageCandidates: .targetOrEmptyWhenRemainingZero,
                    horrorCandidates: .target
                ),
                EnemyAttackAssignmentChoiceSpec(
                    kind: .horror,
                    direct: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 0),
                    damageCandidates: .targetOrEmptyWhenRemainingZero,
                    horrorCandidates: .target
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
                    damageCandidates: .target,
                    horrorCandidates: .targetOrEmptyWhenRemainingZero
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
                    damageCandidates: .target,
                    horrorCandidates: .targetOrEmptyWhenRemainingZero
                ),
                EnemyAttackAssignmentChoiceSpec(
                    kind: .damage,
                    direct: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 0),
                    damageCandidates: .target,
                    horrorCandidates: .targetOrEmptyWhenRemainingZero
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
    case target
    case targetOrEmptyWhenRemainingZero
}

private extension EnemyAttackAssignmentKind {
    var tokenType: String {
        switch self {
        case .damage: "DamageToken"
        case .horror: "HorrorToken"
        }
    }
}
