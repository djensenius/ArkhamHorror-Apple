import Foundation

extension BasicChoiceParser {
    static func isCoverUpReactionCandidate(
        _ object: [String: JSONValue]
    ) -> Bool {
        guard object["tag"] == .string("AbilityLabel"),
              case let .object(ability)? = object["ability"]
        else { return false }
        let matchesDeclaredAbility = ability["cardCode"] == .string(coverUpCardCode)
            || hasWouldDiscoverCluesTag(ability["window"])
        if matchesDeclaredAbility {
            return true
        }
        let matchesTypedAbility = if case let .object(type)? = ability["type"] {
            hasWouldDiscoverCluesTag(type["window"])
        } else {
            false
        }
        if matchesTypedAbility {
            return true
        }
        guard case let .array(windows)? = object["windows"] else { return false }
        return windows.contains { window in
            guard case let .object(windowObject) = window else { return false }
            return hasWouldDiscoverCluesTag(windowObject["windowType"])
        }
    }

    static func parseCoverUpReaction(
        _ object: [String: JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(object.keys) == [
            "tag", "investigatorId", "ability", "windows", "before", "messages",
        ],
            object["tag"] == .string("AbilityLabel"),
            let investigatorID = coverUpInvestigatorID(object["investigatorId"]),
            let abilityIdentity = parseCoverUpReactionAbility(object["ability"]),
            case let .array(windows)? = object["windows"],
            windows.count == 1,
            let windowIdentity = parseCoverUpReactionWindow(windows[0]),
            object["before"] == .array([]),
            object["messages"] == .array([])
        else { return nil }

        let ability = BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: abilityIdentity.cardCode,
            rawAbility: object["ability"] ?? .null,
            windows: windows,
            before: [],
            messages: []
        )
        return .coverUpReaction(CoverUpReactionChoice(
            ability: ability,
            treacheryID: abilityIdentity.treacheryID,
            locationID: windowIdentity.locationID,
            skillTestID: windowIdentity.skillTestID
        ))
    }

    static func validateCoverUpReactionQuestion(
        kind: BasicChoiceQuestionKind, choices: [BasicChoice]
    ) -> Bool? {
        let reactions = choices.compactMap { choice -> CoverUpReactionChoice? in
            guard case let .coverUpReaction(reaction) = choice.content else {
                return nil
            }
            return reaction
        }
        guard !reactions.isEmpty else { return nil }
        guard kind == .windowChooseOne,
              choices.count == 2,
              reactions.count == 1,
              case let .coverUpReaction(reaction) = choices[0].content,
              case let .skipTriggers(skipInvestigatorID) = choices[1].content
        else { return false }
        return reaction.ability.investigatorID == skipInvestigatorID
    }
}

private extension BasicChoiceParser {
    struct CoverUpAbilityIdentity {
        let cardCode: CardCode
        let treacheryID: TreacheryID
    }

    struct CoverUpWindowIdentity {
        let locationID: LocationID
        let skillTestID: SkillTestID
    }

    static let coverUpInvestigatorCardCode = "c01001"
    static let coverUpCardCode = "c01007"

    static let coverUpAbilityKeys: Set<String> = [
        "additionalCosts", "basic", "canBeCancelled", "cardCode", "criteria",
        "delayAdditionalCosts", "displayAs", "doesNotProvokeAttacksOfOpportunity",
        "evadeCriteriaOverride", "fightCriteriaOverride", "highlightFromWindow",
        "ignoreAllCosts", "index", "limit", "metadata", "requestor", "skipForAll",
        "source", "target", "tooltip", "triggersSkillTest", "type", "wantsSkillTest",
        "window",
    ]

    static var coverUpAbilityFixedValues: [String: JSONValue] {
        [
            "additionalCosts": .array([]),
            "basic": .bool(false),
            "canBeCancelled": .bool(true),
            "delayAdditionalCosts": .null,
            "displayAs": .null,
            "doesNotProvokeAttacksOfOpportunity": .null,
            "evadeCriteriaOverride": .null,
            "fightCriteriaOverride": .null,
            "highlightFromWindow": .bool(false),
            "ignoreAllCosts": .bool(false),
            "metadata": .null,
            "skipForAll": .bool(false),
            "target": .null,
            "tooltip": .null,
            "triggersSkillTest": .bool(false),
            "wantsSkillTest": .null,
        ]
    }

    static func parseCoverUpReactionAbility(
        _ value: JSONValue?
    ) -> CoverUpAbilityIdentity? {
        guard case let .object(ability)? = value,
              Set(ability.keys) == coverUpAbilityKeys,
              coverUpAbilityFixedValues.allSatisfy({
                  ability[$0.key] == $0.value
              }),
              case let .string(cardCodeText)? = ability["cardCode"],
              cardCodeText == coverUpCardCode,
              let cardCode = strictCardCode(cardCodeText),
              coverUpCanonicalInteger(ability["index"], equalTo: 1),
              coverUpReactionLimitIsCanonical(ability["limit"]),
              coverUpReactionCriteriaIsCanonical(ability["criteria"]),
              coverUpReactionAbilityTypeIsCanonical(ability["type"]),
              coverUpReactionMatcherIsCanonical(ability["window"]),
              let sourceID = coverUpTreacherySource(ability["source"]),
              let requestorID = coverUpTreacherySource(ability["requestor"]),
              sourceID == requestorID
        else { return nil }
        return CoverUpAbilityIdentity(cardCode: cardCode, treacheryID: sourceID)
    }

    static func parseCoverUpReactionWindow(
        _ value: JSONValue
    ) -> CoverUpWindowIdentity? {
        guard case let .object(window) = value,
              Set(window.keys) == ["windowBatchId", "windowTiming", "windowType"],
              window["windowBatchId"] == .null,
              window["windowTiming"] == .string("When"),
              case let .object(windowType)? = window["windowType"],
              Set(windowType.keys) == ["tag", "contents"],
              windowType["tag"] == .string("WouldDiscoverClues"),
              case let .array(contents)? = windowType["contents"],
              contents.count == 5,
              contents[0] == .string(coverUpInvestigatorCardCode),
              let locationID = coverUpLocationID(contents[1]),
              let skillTestID = coverUpSkillTestID(contents[2]),
              coverUpRolandAbilitySourceIsCanonical(contents[3]),
              coverUpCanonicalInteger(contents[4], equalTo: 1)
        else { return nil }
        return CoverUpWindowIdentity(locationID: locationID, skillTestID: skillTestID)
    }

    static func coverUpReactionLimitIsCanonical(_ value: JSONValue?) -> Bool {
        guard case let .object(limit)? = value,
              Set(limit.keys) == ["tag", "contents"],
              limit["tag"] == .string("PlayerLimit"),
              case let .array(contents)? = limit["contents"],
              contents.count == 2,
              contents[0] == .object(["tag": .string("PerWindow")])
        else { return false }
        return coverUpCanonicalInteger(contents[1], equalTo: 1)
    }

    static func coverUpReactionCriteriaIsCanonical(_ value: JSONValue?) -> Bool {
        guard case let .object(criteria)? = value,
              Set(criteria.keys) == ["tag", "contents"],
              criteria["tag"] == .string("Criteria"),
              case let .array(contents)? = criteria["contents"],
              contents.count == 2,
              contents[0] == .object(["tag": .string("OnSameLocation")]),
              case let .object(cluesOnThis) = contents[1],
              Set(cluesOnThis.keys) == ["tag", "contents"],
              cluesOnThis["tag"] == .string("CluesOnThis")
        else { return false }
        return coverUpAtLeastOneIsCanonical(cluesOnThis["contents"])
    }

    static func coverUpReactionAbilityTypeIsCanonical(_ value: JSONValue?) -> Bool {
        guard case let .object(type)? = value,
              Set(type.keys) == ["tag", "window", "cost", "actions"],
              type["tag"] == .string("ReactionAbility"),
              coverUpReactionMatcherIsCanonical(type["window"]),
              type["cost"] == .object(["tag": .string("Free")]),
              type["actions"] == .object([
                  "tag": .string("AndActions"),
                  "contents": .array([]),
              ])
        else { return false }
        return true
    }

    static func coverUpReactionMatcherIsCanonical(_ value: JSONValue?) -> Bool {
        guard case let .object(matcher)? = value,
              Set(matcher.keys) == ["tag", "contents"],
              matcher["tag"] == .string("WouldDiscoverClues"),
              case let .array(contents)? = matcher["contents"],
              contents.count == 4,
              contents[0] == .string("When"),
              contents[1] == .object(["tag": .string("You")]),
              contents[2] == .object([
                  "tag": .string("LocationWithInvestigator"),
                  "contents": .object(["tag": .string("You")]),
              ]),
              coverUpAtLeastOneIsCanonical(contents[3])
        else { return false }
        return true
    }

    static func coverUpAtLeastOneIsCanonical(_ value: JSONValue?) -> Bool {
        guard case let .object(atLeastOne)? = value,
              Set(atLeastOne.keys) == ["tag", "contents"],
              atLeastOne["tag"] == .string("GreaterThanOrEqualTo"),
              case let .object(staticAmount)? = atLeastOne["contents"],
              Set(staticAmount.keys) == ["tag", "contents"],
              staticAmount["tag"] == .string("Static")
        else { return false }
        return coverUpCanonicalInteger(staticAmount["contents"], equalTo: 1)
    }

    static func coverUpRolandAbilitySourceIsCanonical(_ value: JSONValue) -> Bool {
        guard case let .object(source) = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("AbilitySource"),
              case let .array(contents)? = source["contents"],
              contents.count == 2,
              contents[0] == .object([
                  "tag": .string("InvestigatorSource"),
                  "contents": .string(coverUpInvestigatorCardCode),
              ])
        else { return false }
        return coverUpCanonicalInteger(contents[1], equalTo: 1)
    }

    static func coverUpTreacherySource(_ value: JSONValue?) -> TreacheryID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("TreacherySource"),
              case let .string(rawID)? = source["contents"]
        else { return nil }
        return TreacheryID(codingKey: AnyCodingKey(stringValue: rawID))
    }

    static func coverUpInvestigatorID(_ value: JSONValue?) -> InvestigatorID? {
        guard case let .string(raw)? = value,
              raw == coverUpInvestigatorCardCode,
              let cardCode = strictCardCode(raw)
        else { return nil }
        return InvestigatorID(cardCode)
    }

    static func coverUpLocationID(_ value: JSONValue) -> LocationID? {
        guard case let .string(raw) = value else { return nil }
        return LocationID(codingKey: AnyCodingKey(stringValue: raw))
    }

    static func coverUpSkillTestID(_ value: JSONValue) -> SkillTestID? {
        guard case let .string(raw) = value else { return nil }
        return SkillTestID(codingKey: AnyCodingKey(stringValue: raw))
    }

    static func coverUpCanonicalInteger(
        _ value: JSONValue?, equalTo expected: Int64
    ) -> Bool {
        guard isCanonicalInteger(value),
              case let .number(number)? = value
        else { return false }
        return number.rawToken == String(expected)
    }

    static func hasWouldDiscoverCluesTag(_ value: JSONValue?) -> Bool {
        guard case let .object(object)? = value else { return false }
        return object["tag"] == .string("WouldDiscoverClues")
    }
}
