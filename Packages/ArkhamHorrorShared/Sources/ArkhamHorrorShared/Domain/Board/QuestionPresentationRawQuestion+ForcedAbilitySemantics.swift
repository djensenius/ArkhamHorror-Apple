import Foundation

extension QuestionPresentationRawQuestionShape {
    func validateTreacheryForcedAbilities(
        for presentation: QuestionPresentation
    ) throws -> Bool {
        let expected = choices.enumerated().compactMap {
            treacheryForcedAbilityDescriptor(
                rawChoice: $0.element,
                sourceIndex: $0.offset
            )
        }
        let actual = presentation.choices.filter {
            $0.kind == .resolveForcedAbility && $0.entity?.kind == .treachery
        }
        guard !expected.isEmpty || !actual.isEmpty else { return false }
        guard expected == actual else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        return true
    }

    private func treacheryForcedAbilityDescriptor(
        rawChoice: JSONValue,
        sourceIndex: Int
    ) -> QuestionPresentation.Choice? {
        guard case let .object(choice) = rawChoice,
              Set(choice.keys) == [
                  "tag", "investigatorId", "ability", "windows", "before", "messages",
              ],
              choice["tag"] == .string("AbilityLabel"),
              case let .string(actorID)? = choice["investigatorId"],
              (try? CardCode(actorID)) != nil,
              case let .array(windows)? = choice["windows"],
              windows.allSatisfy(Self.isObject),
              case .array? = choice["before"],
              case .array? = choice["messages"],
              case let .object(ability)? = choice["ability"],
              Self.treacheryForcedAbilityHasAllowedKeys(ability),
              Self.treacheryForcedAbilityBlockingFieldsAreCanonical(ability),
              case let .object(source)? = ability["source"],
              let treacheryID = Self.treacherySourceID(source),
              ability["requestor"] == .object(source),
              ability["target"] == .null,
              ability["additionalCosts"] == .array([]),
              ability["ignoreAllCosts"] == .bool(false),
              case let .string(cardCode)? = ability["cardCode"],
              (try? CardCode(cardCode)) != nil,
              let abilityIndex = Self.canonicalNonNegativeInteger(
                  ability["index"]
              ),
              case let .object(type)? = ability["type"],
              Set(type.keys) == ["tag", "window"],
              type["tag"] == .string("ForcedAbility"),
              case .object? = type["window"],
              case let .bool(canBeCancelled)? = ability["canBeCancelled"]
        else { return nil }

        return QuestionPresentation.Choice(
            sourceIndex: sourceIndex,
            kind: .resolveForcedAbility,
            actorID: actorID,
            entity: .init(kind: .treachery, id: treacheryID),
            label: nil,
            ability: .init(
                cardCode: cardCode,
                index: abilityIndex,
                type: .forced,
                actions: [],
                canBeCancelled: canBeCancelled
            ),
            cost: .free
        )
    }

    private static let treacheryForcedAbilityKeys: Set<String> = [
        "additionalCosts", "basic", "canBeCancelled", "cardCode", "criteria",
        "delayAdditionalCosts", "displayAs", "doesNotProvokeAttacksOfOpportunity",
        "evadeCriteriaOverride", "fightCriteriaOverride", "highlightFromWindow",
        "ignoreAllCosts", "index", "limit", "metadata", "requestor", "skipForAll",
        "source", "target", "tooltip", "triggersSkillTest", "type", "wantsSkillTest",
        "window",
    ]

    private static func treacheryForcedAbilityHasAllowedKeys(
        _ ability: [String: JSONValue]
    ) -> Bool {
        let additiveKeys: Set = ["blocksIn", "nonBlocking"]
        return Set(ability.keys).subtracting(additiveKeys) == treacheryForcedAbilityKeys
    }

    private static func treacheryForcedAbilityBlockingFieldsAreCanonical(
        _ ability: [String: JSONValue]
    ) -> Bool {
        (ability["blocksIn"] == nil || ability["blocksIn"] == .null)
            && (ability["nonBlocking"] == nil || ability["nonBlocking"] == .bool(false))
    }

    private static func treacherySourceID(
        _ source: [String: JSONValue]
    ) -> String? {
        guard Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("TreacherySource"),
              case let .string(rawID)? = source["contents"],
              TreacheryID(codingKey: AnyCodingKey(stringValue: rawID)) != nil
        else { return nil }
        return rawID
    }

    private static func canonicalNonNegativeInteger(
        _ value: JSONValue?
    ) -> Int? {
        guard case let .number(number)? = value,
              number.sign == .plus,
              let token = number.rawToken,
              !token.isEmpty,
              token.allSatisfy(\.isASCIIWholeNumber),
              token == "0" || token.first != "0"
        else { return nil }
        return Int(token)
    }

    private static func isObject(_ value: JSONValue) -> Bool {
        guard case .object = value else { return false }
        return true
    }
}
