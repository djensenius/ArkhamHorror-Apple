import Foundation

extension BasicChoiceParser {
    /// Revision 0.1.32's isolated Ghoul Minion assignment root, not a general
    /// `QuestionWithSource`, `QuestionLabel`, `ComponentLabel`, or damage-assignment
    /// decoder.
    static func parseEnemyAttackDamageAssignmentQuestion(
        _ object: [String: JSONValue], rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard Set(object.keys) == ["tag", "source", "tooltip", "question"],
              object["tag"] == .string(BasicChoiceQuestionKind.questionWithSource.rawValue),
              let outerEnemyID = enemyAttackSourceID(object["source"]),
              object["tooltip"] == .null
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }
        guard
            case let .object(labelQuestion)? = object["question"],
            Set(labelQuestion.keys) == ["tag", "label", "card", "question"],
            labelQuestion["tag"] == .string("QuestionLabel"),
            labelQuestion["label"] == .string("Assign 1 damage and 1 horror"),
            labelQuestion["card"] == .null
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }
        guard
            case let .object(chooseOne)? = labelQuestion["question"],
            Set(chooseOne.keys) == ["tag", "choices"],
            chooseOne["tag"] == .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            case let .array(rawChoices)? = chooseOne["choices"],
            rawChoices.count == 2
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }
        guard
            let damage = parseDamageAssignmentChoice(
                rawChoices[0], kind: .damage, outerEnemyID: outerEnemyID
            ),
            let horror = parseDamageAssignmentChoice(
                rawChoices[1], kind: .horror, outerEnemyID: outerEnemyID
            ),
            damage.investigatorID == horror.investigatorID
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }

        return .supported(BasicChoiceQuestion(
            kind: .questionWithSource,
            choices: [
                BasicChoice(index: 0, rawValue: rawChoices[0], content: damage.content),
                BasicChoice(index: 1, rawValue: rawChoices[1], content: horror.content),
            ],
            story: nil,
            rawValue: rawValue
        ))
    }

    private struct ParsedDamageAssignmentChoice {
        let investigatorID: InvestigatorID
        let content: BasicChoiceContent
    }

    private static func parseDamageAssignmentChoice(
        _ value: JSONValue,
        kind: EnemyAttackAssignmentKind,
        outerEnemyID: EnemyID
    ) -> ParsedDamageAssignmentChoice? {
        guard case let .object(object) = value,
              Set(object.keys) == ["tag", "component", "messages"],
              object["tag"] == .string("ComponentLabel"),
              case let .object(component)? = object["component"],
              Set(component.keys) == ["tag", "investigatorId", "tokenType"],
              component["tag"] == .string("InvestigatorComponent"),
              case let .string(rawInvestigatorID)? = component["investigatorId"],
              let investigatorCode = strictCardCode(rawInvestigatorID),
              component["tokenType"] == .string(kind.tokenType),
              case let .array(messages)? = object["messages"],
              messages.count == 2
        else { return nil }

        let investigatorID = InvestigatorID(investigatorCode)
        guard damageMessage(
            messages[0],
            investigatorID: investigatorID,
            enemyID: outerEnemyID,
            damage: kind.directDamage,
            horror: kind.directHorror
        ),
            assignmentContinuation(
                messages[1],
                investigatorID: investigatorID,
                enemyID: outerEnemyID,
                kind: kind
            )
        else { return nil }

        return ParsedDamageAssignmentChoice(
            investigatorID: investigatorID,
            content: .assignEnemyAttackDamage(EnemyAttackDamageAssignment(
                kind: kind,
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
        damage: Int64,
        horror: Int64
    ) -> Bool {
        guard let contents = investigatorMessageContents(value, tag: "InvestigatorDamage_"),
              contents.count == 4,
              contents[0] == .string(investigatorID.rawValue.rawValue),
              enemyAttackSourceID(contents[1]) == enemyID,
              canonicalInteger(contents[2], equals: damage),
              canonicalInteger(contents[3], equals: horror)
        else { return false }
        return true
    }

    private static func assignmentContinuation(
        _ value: JSONValue,
        investigatorID: InvestigatorID,
        enemyID: EnemyID,
        kind: EnemyAttackAssignmentKind
    ) -> Bool {
        guard let contents = investigatorMessageContents(
            value, tag: "InvestigatorDoAssignDamage_"
        ),
            contents.count == 8,
            contents[0] == .string(investigatorID.rawValue.rawValue),
            enemyAttackSourceID(contents[1]) == enemyID,
            contents[2] == .object(["tag": .string("DamageAny")]),
            contents[3] == .object(["tag": .string("AnyAsset")]),
            canonicalInteger(contents[4], equals: kind.remainingDamage),
            canonicalInteger(contents[5], equals: kind.remainingHorror),
            candidateList(
                contents[6], expected: kind == .damage ? investigatorID : nil
            ),
            candidateList(
                contents[7], expected: kind == .horror ? investigatorID : nil
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
        expected investigatorID: InvestigatorID?
    ) -> Bool {
        guard case let .array(candidates) = value else { return false }
        guard let investigatorID else { return candidates.isEmpty }
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

private extension EnemyAttackAssignmentKind {
    var tokenType: String {
        switch self {
        case .damage: "DamageToken"
        case .horror: "HorrorToken"
        }
    }

    var directDamage: Int64 {
        self == .damage ? 1 : 0
    }

    var directHorror: Int64 {
        self == .horror ? 1 : 0
    }

    var remainingDamage: Int64 {
        self == .damage ? 0 : 1
    }

    var remainingHorror: Int64 {
        self == .damage ? 1 : 0
    }
}
