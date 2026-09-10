import Foundation

extension BasicChoiceParser {
    /// Revision 0.1.31's isolated enemy-attack root, not a general
    /// `ChooseOneAtATime`, `EnemyTarget`, or `EnemyAttackMessage` decoder.
    static func parseEnemyAttackQuestion(
        _ object: [String: JSONValue], rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard Set(object.keys) == ["tag", "choices"],
              object["tag"] == .string(BasicChoiceQuestionKind.chooseOneAtATime.rawValue),
              case let .array(rawChoices)? = object["choices"],
              rawChoices.count == 1,
              let content = parseEnemyAttackChoice(rawChoices[0])
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.chooseOneAtATime.rawValue)
        }
        return .supported(BasicChoiceQuestion(
            kind: .chooseOneAtATime,
            choices: [BasicChoice(index: 0, rawValue: rawChoices[0], content: content)],
            story: nil,
            rawValue: rawValue
        ))
    }

    private static func parseEnemyAttackChoice(_ value: JSONValue) -> BasicChoiceContent? {
        guard case let .object(object) = value,
              Set(object.keys) == ["tag", "target", "messages"],
              object["tag"] == .string("TargetLabel"),
              let targetEnemyID = enemyID(object["target"]),
              case let .array(messages)? = object["messages"],
              messages.count == 1,
              case let .object(message) = messages[0],
              Set(message.keys) == ["tag", "contents"],
              message["tag"] == .string("EnemyAttackMessage"),
              case let .object(constructor)? = message["contents"],
              Set(constructor.keys) == ["tag", "contents"],
              constructor["tag"] == .string("EnemyAttack_"),
              case let .object(attack)? = constructor["contents"],
              Set(attack.keys) == [
                  "attackTarget", "attackOriginalTarget", "attackEnemy", "attackType",
                  "attackDamageStrategy", "attackExhaustsEnemy", "attackSource",
                  "attackCanBeCanceled", "attackAfter", "attackDamaged", "attackDealDamage",
                  "attackDespiteExhausted", "attackCancelled",
              ],
              let investigatorID = attackInvestigatorID(attack["attackTarget"]),
              let originalInvestigatorID = attackInvestigatorID(
                  attack["attackOriginalTarget"]
              ),
              investigatorID == originalInvestigatorID,
              let attackEnemyID = canonicalEnemyID(attack["attackEnemy"]),
              let sourceEnemyID = enemySourceID(attack["attackSource"]),
              targetEnemyID == attackEnemyID,
              attackEnemyID == sourceEnemyID,
              attack["attackType"] == .string("RegularAttack"),
              attack["attackDamageStrategy"] == .object(["tag": .string("DamageAny")]),
              attack["attackExhaustsEnemy"] == .bool(true),
              attack["attackCanBeCanceled"] == .bool(true),
              attack["attackAfter"] == .array([]),
              attack["attackDamaged"] == .array([]),
              attack["attackDealDamage"] == .bool(true),
              attack["attackDespiteExhausted"] == .bool(false),
              attack["attackCancelled"] == .bool(false)
        else { return nil }
        return .resolveEnemyAttack(
            enemyID: targetEnemyID, investigatorID: investigatorID, messages: messages
        )
    }

    private static func enemyID(_ value: JSONValue?) -> EnemyID? {
        guard case let .object(target)? = value,
              Set(target.keys) == ["tag", "contents"],
              target["tag"] == .string("EnemyTarget")
        else { return nil }
        return canonicalEnemyID(target["contents"])
    }

    private static func canonicalEnemyID(_ value: JSONValue?) -> EnemyID? {
        guard case let .string(raw)? = value else { return nil }
        return EnemyID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private static func enemySourceID(_ value: JSONValue?) -> EnemyID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("EnemySource")
        else { return nil }
        return canonicalEnemyID(source["contents"])
    }

    private static func attackInvestigatorID(_ value: JSONValue?) -> InvestigatorID? {
        guard case let .object(singleTarget)? = value,
              Set(singleTarget.keys) == ["tag", "contents"],
              singleTarget["tag"] == .string("SingleAttackTarget"),
              case let .object(target)? = singleTarget["contents"],
              Set(target.keys) == ["tag", "contents"],
              target["tag"] == .string("InvestigatorTarget"),
              case let .string(rawInvestigatorID)? = target["contents"],
              let cardCode = strictCardCode(rawInvestigatorID)
        else { return nil }
        return InvestigatorID(cardCode)
    }
}
