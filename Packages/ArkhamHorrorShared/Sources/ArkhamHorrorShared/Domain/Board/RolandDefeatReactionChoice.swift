import Foundation

extension BasicChoiceParser {
    static func parseRolandDefeatReaction(
        _ object: [String: JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(object.keys) == [
            "tag", "investigatorId", "ability", "windows", "before", "messages",
        ],
            object["tag"] == .string("AbilityLabel"),
            let investigatorID = rolandInvestigatorID(object["investigatorId"]),
            let cardCode = parseRolandDefeatReactionAbility(object["ability"]),
            case let .array(windows)? = object["windows"],
            windows.count == 1,
            let enemyID = rolandDefeatedEnemyID(windows[0]),
            object["before"] == .array([]),
            object["messages"] == .array([])
        else { return nil }

        let ability = BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: cardCode,
            rawAbility: object["ability"] ?? .null,
            windows: windows,
            before: [],
            messages: []
        )
        return .rolandDefeatReaction(RolandDefeatReactionChoice(
            ability: ability,
            defeatedEnemyID: enemyID
        ))
    }

    static func validateRolandDefeatReactionQuestion(
        kind: BasicChoiceQuestionKind, choices: [BasicChoice]
    ) -> Bool? {
        let reactions = choices.compactMap { choice -> RolandDefeatReactionChoice? in
            guard case let .rolandDefeatReaction(reaction) = choice.content else {
                return nil
            }
            return reaction
        }
        guard !reactions.isEmpty else { return nil }
        guard kind == .windowChooseOne,
              choices.count == 2,
              reactions.count == 1,
              case let .rolandDefeatReaction(reaction) = choices[0].content,
              case let .skipTriggers(skipInvestigatorID) = choices[1].content
        else { return false }
        return reaction.ability.investigatorID == skipInvestigatorID
    }
}

private extension BasicChoiceParser {
    static let rolandCardCode = "c01001"

    static let rolandAbilityKeys: Set<String> = [
        "additionalCosts", "basic", "canBeCancelled", "cardCode", "criteria",
        "delayAdditionalCosts", "displayAs", "doesNotProvokeAttacksOfOpportunity",
        "evadeCriteriaOverride", "fightCriteriaOverride", "highlightFromWindow",
        "ignoreAllCosts", "index", "limit", "metadata", "requestor", "skipForAll",
        "source", "target", "tooltip", "triggersSkillTest", "type", "wantsSkillTest",
        "window",
    ]

    static var rolandAbilityFixedValues: [String: JSONValue] {
        [
            "additionalCosts": .array([]),
            "basic": .bool(false),
            "canBeCancelled": .bool(true),
            "criteria": rolandReactionCriteria,
            "delayAdditionalCosts": .null,
            "displayAs": .null,
            "doesNotProvokeAttacksOfOpportunity": .null,
            "evadeCriteriaOverride": .null,
            "fightCriteriaOverride": .null,
            "highlightFromWindow": .bool(false),
            "ignoreAllCosts": .bool(false),
            "limit": rolandReactionLimit,
            "metadata": .null,
            "requestor": rolandInvestigatorSource,
            "skipForAll": .bool(false),
            "source": rolandInvestigatorSource,
            "target": .null,
            "tooltip": .null,
            "triggersSkillTest": .bool(false),
            "type": rolandReactionAbilityType,
            "wantsSkillTest": .null,
            "window": rolandReactionMatcher,
        ]
    }

    static func parseRolandDefeatReactionAbility(_ value: JSONValue?) -> CardCode? {
        guard case let .object(ability)? = value,
              Set(ability.keys) == rolandAbilityKeys,
              rolandAbilityFixedValues.allSatisfy({
                  ability[$0.key] == $0.value
              }),
              case let .string(cardCodeText)? = ability["cardCode"],
              cardCodeText == rolandCardCode,
              let cardCode = strictCardCode(cardCodeText),
              rolandCanonicalInteger(ability["index"], equalTo: 1),
              rolandReactionLimitIsCanonical(ability["limit"])
        else { return nil }
        return cardCode
    }

    static func rolandInvestigatorID(_ value: JSONValue?) -> InvestigatorID? {
        guard case let .string(raw)? = value,
              raw == rolandCardCode,
              let cardCode = strictCardCode(raw)
        else { return nil }
        return InvestigatorID(cardCode)
    }

    static func rolandDefeatedEnemyID(_ value: JSONValue) -> EnemyID? {
        guard case let .object(window) = value,
              Set(window.keys) == ["windowBatchId", "windowTiming", "windowType"],
              window["windowBatchId"] == .null,
              window["windowTiming"] == .string("After"),
              case let .object(windowType)? = window["windowType"],
              Set(windowType.keys) == ["tag", "contents"],
              windowType["tag"] == .string("IfEnemyDefeated"),
              case let .array(contents)? = windowType["contents"],
              contents.count == 3,
              contents[0] == .string(rolandCardCode),
              let sourceEnemyID = rolandDefeatedByDamageEnemyID(contents[1]),
              let defeatedEnemyID = rolandEnemyID(contents[2]),
              sourceEnemyID == defeatedEnemyID
        else { return nil }
        return defeatedEnemyID
    }

    static func rolandDefeatedByDamageEnemyID(_ value: JSONValue) -> EnemyID? {
        guard case let .object(defeatedByDamage) = value,
              Set(defeatedByDamage.keys) == ["tag", "contents"],
              defeatedByDamage["tag"] == .string("DefeatedByDamage"),
              case let .object(useAbilitySource)? = defeatedByDamage["contents"],
              Set(useAbilitySource.keys) == ["tag", "contents"],
              useAbilitySource["tag"] == .string("UseAbilitySource"),
              case let .array(contents)? = useAbilitySource["contents"],
              contents.count == 3,
              contents[0] == .string(rolandCardCode),
              let enemyID = rolandEnemySource(contents[1]),
              rolandCanonicalInteger(contents[2], equalTo: 100)
        else { return nil }
        return enemyID
    }

    static func rolandEnemySource(_ value: JSONValue) -> EnemyID? {
        guard case let .object(source) = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("EnemySource")
        else { return nil }
        return rolandEnemyID(source["contents"])
    }

    static func rolandEnemyID(_ value: JSONValue?) -> EnemyID? {
        guard case let .string(raw)? = value else { return nil }
        return EnemyID(codingKey: AnyCodingKey(stringValue: raw))
    }

    static func rolandCanonicalInteger(
        _ value: JSONValue?, equalTo expected: Int64
    ) -> Bool {
        guard isCanonicalInteger(value),
              case let .number(number)? = value
        else { return false }
        return number.rawToken == String(expected)
    }

    static func rolandReactionLimitIsCanonical(_ value: JSONValue?) -> Bool {
        guard case let .object(limit)? = value,
              Set(limit.keys) == ["tag", "contents"],
              limit["tag"] == .string("PlayerLimit"),
              case let .array(contents)? = limit["contents"],
              contents.count == 2,
              contents[0] == .object(["tag": .string("PerRound")])
        else { return false }
        return rolandCanonicalInteger(contents[1], equalTo: 1)
    }

    static var rolandInvestigatorSource: JSONValue {
        .object([
            "tag": .string("InvestigatorSource"),
            "contents": .string(rolandCardCode),
        ])
    }

    static var rolandReactionCriteria: JSONValue {
        .object([
            "tag": .string("Criteria"),
            "contents": .array([
                .object(["tag": .string("Self")]),
                .object([
                    "tag": .string("LocationExists"),
                    "contents": .object([
                        "tag": .string("LocationMatchAll"),
                        "contents": .array([
                            .object([
                                "tag": .string("LocationWithInvestigator"),
                                "contents": .object(["tag": .string("You")]),
                            ]),
                            .object([
                                "tag": .string("LocationWithDiscoverableCluesBy"),
                                "contents": .object(["tag": .string("You")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    static var rolandReactionLimit: JSONValue {
        .object([
            "tag": .string("PlayerLimit"),
            "contents": .array([
                .object(["tag": .string("PerRound")]),
                .number(.integer(1)),
            ]),
        ])
    }

    static var rolandReactionAbilityType: JSONValue {
        .object([
            "tag": .string("ReactionAbility"),
            "window": rolandReactionMatcher,
            "cost": .object(["tag": .string("Free")]),
            "actions": .object([
                "tag": .string("AndActions"),
                "contents": .array([]),
            ]),
        ])
    }

    static var rolandReactionMatcher: JSONValue {
        .object([
            "tag": .string("IfEnemyDefeated"),
            "contents": .array([
                .string("After"),
                .object(["tag": .string("You")]),
                .object(["tag": .string("ByAny")]),
                .object(["tag": .string("AnyEnemy")]),
            ]),
        ])
    }
}
