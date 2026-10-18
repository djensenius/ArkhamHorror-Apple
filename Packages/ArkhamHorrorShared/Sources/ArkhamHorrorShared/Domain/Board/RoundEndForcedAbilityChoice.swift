import Foundation

extension BasicChoiceParser {
    static func parseRoundEndForcedAbility(
        _ object: [String: JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(object.keys) == [
            "tag", "investigatorId", "ability", "windows", "before", "messages",
        ],
            object["tag"] == .string("AbilityLabel"),
            let investigatorID = roundEndInvestigatorID(object["investigatorId"]),
            let identity = parseDissonantVoicesAbility(object["ability"]),
            let rawAbility = object["ability"],
            case let .array(windows)? = object["windows"],
            windows.count == 1,
            roundEndWindowMatches(windows[0]),
            object["before"] == .array([]),
            let messages = roundEndMessages(
                object["messages"],
                investigatorID: object["investigatorId"],
                ability: rawAbility,
                windows: windows
            )
        else { return nil }

        let parsedAbility = BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: identity.cardCode,
            rawAbility: rawAbility,
            windows: windows,
            before: [],
            messages: messages
        )
        return .resolveForcedAbility(ForcedAbilityChoice(
            ability: parsedAbility,
            treacheryID: identity.treacheryID
        ))
    }
}

private extension BasicChoiceParser {
    struct RoundEndAbilityIdentity {
        let cardCode: CardCode
        let treacheryID: TreacheryID
    }

    static func parseDissonantVoicesAbility(
        _ value: JSONValue?
    ) -> RoundEndAbilityIdentity? {
        guard case let .object(ability)? = value,
              let wireShape = roundEndAbilityWireShape(ability),
              roundEndAbilityFixedValues(for: wireShape).allSatisfy({
                  ability[$0.key] == $0.value
              }),
              roundEndAbilityBlockingFieldsAreCanonical(ability),
              isCanonicalInteger(ability["index"], equalTo: 1),
              case let .string(cardCodeText)? = ability["cardCode"],
              cardCodeText == "c01165",
              let cardCode = strictCardCode(cardCodeText),
              let treacheryID = roundEndTreacherySource(ability["source"]),
              roundEndTreacherySource(ability["requestor"]) == treacheryID
        else { return nil }
        return RoundEndAbilityIdentity(cardCode: cardCode, treacheryID: treacheryID)
    }

    enum RoundEndAbilityWireShape {
        case legacy
        case schema153
    }

    /// Dissonant Voices' forced ability is strict for both relevant wire shapes:
    /// the pre-0.1.53 ability object without `chaosTokenEffects`/`resultLabel`,
    /// and the 0.1.53 object with both fields at their canonical values. Mixed
    /// shapes are rejected so partial server drift does not gain answer authority.
    static let roundEndAbilityLegacyKeys: Set<String> = [
        "additionalCosts", "basic", "canBeCancelled", "cardCode", "criteria",
        "delayAdditionalCosts", "displayAs", "doesNotProvokeAttacksOfOpportunity",
        "evadeCriteriaOverride", "fightCriteriaOverride", "highlightFromWindow",
        "ignoreAllCosts", "index", "limit", "metadata", "requestor", "skipForAll",
        "source", "target", "tooltip", "triggersSkillTest", "type", "wantsSkillTest",
        "window",
    ]

    static let roundEndAbilitySchema153Keys: Set<String> = roundEndAbilityLegacyKeys
        .union(["chaosTokenEffects", "resultLabel"])

    static func roundEndAbilityFixedValues(
        for shape: RoundEndAbilityWireShape
    ) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "additionalCosts": .array([]),
            "basic": .bool(false),
            "canBeCancelled": .bool(true),
            "criteria": .object([
                "tag": .string("InThreatAreaOf"),
                "contents": .object(["tag": .string("You")]),
            ]),
            "delayAdditionalCosts": .null,
            "displayAs": .null,
            "doesNotProvokeAttacksOfOpportunity": .null,
            "evadeCriteriaOverride": .null,
            "fightCriteriaOverride": .null,
            "highlightFromWindow": .bool(false),
            "ignoreAllCosts": .bool(false),
            "limit": .object([
                "tag": .string("GroupLimit"),
                "contents": .array([
                    .object(["tag": .string("PerWindow")]),
                    .number(.integer(1)),
                ]),
            ]),
            "metadata": .null,
            "skipForAll": .bool(false),
            "target": .null,
            "tooltip": .null,
            "triggersSkillTest": .bool(false),
            "type": .object([
                "tag": .string("ForcedAbility"),
                "window": roundEndsWhenWindow,
            ]),
            "wantsSkillTest": .null,
            "window": roundEndsWhenWindow,
        ]
        if shape == .schema153 {
            values["chaosTokenEffects"] = .array([])
            values["resultLabel"] = .null
        }
        return values
    }

    static var roundEndsWhenWindow: JSONValue {
        .object([
            "tag": .string("RoundEnds"),
            "contents": .string("When"),
        ])
    }

    static func roundEndAbilityWireShape(
        _ ability: [String: JSONValue]
    ) -> RoundEndAbilityWireShape? {
        let additiveKeys: Set = ["blocksIn", "nonBlocking"]
        let governedKeys = Set(ability.keys).subtracting(additiveKeys)
        if governedKeys == roundEndAbilityLegacyKeys {
            return .legacy
        }
        if governedKeys == roundEndAbilitySchema153Keys {
            return .schema153
        }
        return nil
    }

    static func roundEndAbilityBlockingFieldsAreCanonical(
        _ ability: [String: JSONValue]
    ) -> Bool {
        (ability["blocksIn"] == nil || ability["blocksIn"] == .null)
            && (ability["nonBlocking"] == nil || ability["nonBlocking"] == .bool(false))
    }

    static func roundEndWindowMatches(_ value: JSONValue) -> Bool {
        guard case let .object(window) = value else { return false }
        let additiveKeys: Set = ["windowConditionTick"]
        return Set(window.keys).subtracting(additiveKeys) == [
            "windowBatchId", "windowTiming", "windowType",
        ]
            && window["windowBatchId"] == .null
            && window["windowTiming"] == .string("When")
            && window["windowType"] == .object(["tag": .string("AtEndOfRound")])
            && (window["windowConditionTick"] == nil || window["windowConditionTick"] == .null)
    }

    static func roundEndMessages(
        _ value: JSONValue?,
        investigatorID: JSONValue?,
        ability: JSONValue,
        windows: [JSONValue]
    ) -> [JSONValue]? {
        guard case let .array(messages)? = value else { return nil }
        if messages.isEmpty {
            return messages
        }
        guard messages.count == 1,
              case let .object(message) = messages[0],
              message["tag"] == .string("MoveWithSkillTest"),
              case let .object(contents)? = message["contents"],
              contents["tag"] == .string("ResolveWindowInitiations"),
              case let .array(payload)? = contents["contents"],
              payload.count == 3,
              payload[0] == investigatorID,
              payload[1] == .array(windows),
              payload[2] == .array([
                  .array([
                      ability,
                      .array(windows),
                      .array([]),
                  ]),
              ])
        else { return nil }
        return messages
    }

    static func roundEndTreacherySource(_ value: JSONValue?) -> TreacheryID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("TreacherySource"),
              case let .string(raw)? = source["contents"]
        else { return nil }
        return TreacheryID(codingKey: AnyCodingKey(stringValue: raw))
    }

    static func roundEndInvestigatorID(_ value: JSONValue?) -> InvestigatorID? {
        guard case let .string(raw)? = value,
              let code = strictCardCode(raw)
        else { return nil }
        return InvestigatorID(code)
    }
}
