import Foundation

extension BasicChoiceParser {
    private static let roundTransitionAgendaCardCode = "c01105"

    static func parseQuestionWithSource(
        _ object: [String: JSONValue], rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard case let .object(source)? = object["source"],
              case let .string(tag)? = source["tag"]
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }
        switch tag {
        case "EnemyAttackSource":
            return parseEnemyAttackAssignmentQuestion(object, rawValue: rawValue)
        case "AgendaSource":
            return parseAgendaHorrorAssignmentQuestion(object, rawValue: rawValue)
        default:
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }
    }

    static func validateRoundTransitionQuestion(
        kind: BasicChoiceQuestionKind, choices: [BasicChoice]
    ) -> Bool {
        let forcedChoices = choices.compactMap { choice -> ForcedAbilityChoice? in
            guard case let .resolveForcedAbility(forced) = choice.content else { return nil }
            return forced
        }
        if !forcedChoices.isEmpty {
            return kind == .windowChooseOne
                && choices.count == 1
                && forcedChoices.count == 1
        }

        let agendaAdvanceChoices = choices.compactMap { choice -> AgendaID? in
            guard case let .advanceAgenda(agendaID, _) = choice.content else { return nil }
            return agendaID
        }
        if !agendaAdvanceChoices.isEmpty {
            return kind == .chooseOne
                && choices.count == 1
                && agendaAdvanceChoices.count == 1
        }

        let consequenceChoices = choices.compactMap { choice -> AgendaConsequenceChoice? in
            guard case let .chooseAgendaConsequence(consequence) = choice.content else {
                return nil
            }
            return consequence
        }
        guard !consequenceChoices.isEmpty else { return true }
        guard kind == .chooseOne,
              choices.count == 2,
              consequenceChoices.count == 2,
              case let .chooseAgendaConsequence(horror) = choices[0].content,
              case let .chooseAgendaConsequence(discard) = choices[1].content
        else { return false }
        return horror.kind == .takeHorror
            && discard.kind == .randomDiscard
            && horror.agendaID == discard.agendaID
            && horror.investigatorID != nil
            && discard.investigatorID == nil
    }

    static func parseRoundEndForcedAbility(
        _ object: [String: JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(object.keys) == [
            "tag", "investigatorId", "ability", "windows", "before", "messages",
        ],
            object["tag"] == .string("AbilityLabel"),
            let investigatorID = roundTransitionInvestigatorID(object["investigatorId"]),
            let identity = parseDissonantVoicesAbility(object["ability"]),
            case let .array(windows)? = object["windows"],
            windows == roundEndWindows,
            object["before"] == .array([]),
            object["messages"] == .array([])
        else { return nil }

        let parsedAbility = BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: identity.cardCode,
            rawAbility: object["ability"] ?? .null,
            windows: windows,
            before: [],
            messages: []
        )
        return .resolveForcedAbility(ForcedAbilityChoice(
            ability: parsedAbility,
            treacheryID: identity.treacheryID
        ))
    }

    private struct RoundEndAbilityIdentity {
        let cardCode: CardCode
        let treacheryID: TreacheryID
    }

    private static func parseDissonantVoicesAbility(
        _ value: JSONValue?
    ) -> RoundEndAbilityIdentity? {
        guard case let .object(ability)? = value,
              Set(ability.keys) == roundEndAbilityKeys,
              roundEndAbilityFixedValues.allSatisfy({
                  ability[$0.key] == $0.value
              }),
              isCanonicalInteger(ability["index"], equalTo: 1),
              case let .string(cardCodeText)? = ability["cardCode"],
              cardCodeText == "c01165",
              let cardCode = strictCardCode(cardCodeText),
              let treacheryID = roundTransitionTreacherySource(ability["source"]),
              roundTransitionTreacherySource(ability["requestor"]) == treacheryID
        else { return nil }
        return RoundEndAbilityIdentity(cardCode: cardCode, treacheryID: treacheryID)
    }

    private static let roundEndAbilityKeys: Set<String> = [
        "additionalCosts", "basic", "canBeCancelled", "cardCode", "criteria",
        "delayAdditionalCosts", "displayAs", "doesNotProvokeAttacksOfOpportunity",
        "evadeCriteriaOverride", "fightCriteriaOverride", "highlightFromWindow",
        "ignoreAllCosts", "index", "limit", "metadata", "requestor", "skipForAll",
        "source", "target", "tooltip", "triggersSkillTest", "type", "wantsSkillTest",
        "window",
    ]

    private static let roundEndAbilityFixedValues: [String: JSONValue] = [
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

    private static let roundEndWindows: [JSONValue] = [
        .object([
            "windowBatchId": .null,
            "windowTiming": .string("When"),
            "windowType": .object(["tag": .string("AtEndOfRound")]),
        ]),
    ]

    static func parseAdvanceAgendaTarget(
        _ target: [String: JSONValue], messages: [JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(target.keys) == ["tag", "contents"],
              target["tag"] == .string("AgendaTarget"),
              let agendaID = roundTransitionAgendaID(target["contents"]),
              agendaID.rawValue.rawValue == roundTransitionAgendaCardCode,
              messages.count == 1,
              case let .object(message) = messages[0],
              Set(message.keys) == ["tag", "contents"],
              message["tag"] == .string("AdvanceAgendaBy"),
              case let .array(contents)? = message["contents"],
              contents.count == 2,
              contents[0] == .string(agendaID.rawValue.rawValue),
              contents[1] == .string("AgendaAdvancedWithDoom")
        else { return nil }
        return .advanceAgenda(agendaID: agendaID, messages: messages)
    }

    static func parseAgendaConsequenceLabel(
        _ object: [String: JSONValue], messages: [JSONValue]
    ) -> BasicChoiceContent? {
        guard case let .string(label)? = object["label"] else { return nil }
        switch label {
        case "$nightOfTheZealot.theGathering.label.whatsGoingOn.horror":
            guard messages.count == 1,
                  let contents = roundTransitionInvestigatorMessageContents(
                      messages[0], tag: "InvestigatorAssignDamage_"
                  ),
                  contents.count == 5,
                  let investigatorID = roundTransitionInvestigatorID(contents[0]),
                  let agendaID = roundTransitionAgendaSource(contents[1]),
                  contents[2] == .object(["tag": .string("DamageAny")]),
                  isCanonicalInteger(contents[3], equalTo: 0),
                  isCanonicalInteger(contents[4], equalTo: 2)
            else { return nil }
            return .chooseAgendaConsequence(AgendaConsequenceChoice(
                kind: .takeHorror,
                label: label,
                agendaID: agendaID,
                investigatorID: investigatorID,
                messages: messages
            ))
        case "$nightOfTheZealot.theGathering.label.whatsGoingOn.discard":
            guard messages.count == 1,
                  case let .object(message) = messages[0],
                  Set(message.keys) == ["tag", "contents"],
                  message["tag"] == .string("AllRandomDiscard"),
                  case let .array(contents)? = message["contents"],
                  contents.count == 2,
                  let agendaID = roundTransitionAgendaSource(contents[0]),
                  contents[1] == .object(["tag": .string("AnyCard")])
            else { return nil }
            return .chooseAgendaConsequence(AgendaConsequenceChoice(
                kind: .randomDiscard,
                label: label,
                agendaID: agendaID,
                investigatorID: nil,
                messages: messages
            ))
        default:
            return nil
        }
    }

    static func parseAgendaHorrorAssignmentQuestion(
        _ object: [String: JSONValue], rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard Set(object.keys) == ["tag", "source", "tooltip", "question"],
              object["tag"] == .string(BasicChoiceQuestionKind.questionWithSource.rawValue),
              let agendaID = roundTransitionAgendaSource(object["source"]),
              object["tooltip"] == .null,
              case let .object(labelQuestion)? = object["question"],
              Set(labelQuestion.keys) == ["tag", "label", "card", "question"],
              labelQuestion["tag"] == .string("QuestionLabel"),
              labelQuestion["label"] == .string("Assign 2 horror"),
              labelQuestion["card"] == .null,
              case let .object(chooseOne)? = labelQuestion["question"],
              Set(chooseOne.keys) == ["tag", "choices"],
              chooseOne["tag"] == .string(BasicChoiceQuestionKind.chooseOne.rawValue),
              case let .array(rawChoices)? = chooseOne["choices"],
              rawChoices.count == 1,
              let assignment = parseAgendaHorrorAssignment(
                  rawChoices[0], agendaID: agendaID
              )
        else {
            return .updateRequired(tag: BasicChoiceQuestionKind.questionWithSource.rawValue)
        }

        return .supported(BasicChoiceQuestion(
            kind: .questionWithSource,
            choices: [
                BasicChoice(
                    index: 0,
                    rawValue: rawChoices[0],
                    content: .assignAgendaHorror(assignment)
                ),
            ],
            story: nil,
            rawValue: rawValue
        ))
    }

    private static func parseAgendaHorrorAssignment(
        _ value: JSONValue, agendaID: AgendaID
    ) -> AgendaHorrorAssignment? {
        guard case let .object(object) = value,
              Set(object.keys) == ["tag", "component", "messages"],
              object["tag"] == .string("ComponentLabel"),
              case let .object(component)? = object["component"],
              Set(component.keys) == ["tag", "investigatorId", "tokenType"],
              component["tag"] == .string("InvestigatorComponent"),
              let investigatorID = roundTransitionInvestigatorID(component["investigatorId"]),
              component["tokenType"] == .string("HorrorToken"),
              case let .array(messages)? = object["messages"],
              messages.count == 2,
              let direct = roundTransitionInvestigatorMessageContents(
                  messages[0], tag: "InvestigatorDamage_"
              ),
              direct.count == 4,
              direct[0] == .string(investigatorID.rawValue.rawValue),
              roundTransitionAgendaSource(direct[1]) == agendaID,
              isCanonicalInteger(direct[2], equalTo: 0),
              isCanonicalInteger(direct[3], equalTo: 2),
              let continuation = roundTransitionInvestigatorMessageContents(
                  messages[1], tag: "InvestigatorDoAssignDamage_"
              ),
              continuation.count == 8,
              continuation[0] == .string(investigatorID.rawValue.rawValue),
              roundTransitionAgendaSource(continuation[1]) == agendaID,
              continuation[2] == .object(["tag": .string("DamageAny")]),
              continuation[3] == .object(["tag": .string("AnyAsset")]),
              isCanonicalInteger(continuation[4], equalTo: 0),
              isCanonicalInteger(continuation[5], equalTo: 0),
              continuation[6] == .array([]),
              continuation[7] == .array([
                  investigatorTarget(investigatorID),
                  investigatorTarget(investigatorID),
              ])
        else { return nil }
        return AgendaHorrorAssignment(
            agendaID: agendaID,
            investigatorID: investigatorID,
            messages: messages
        )
    }

    private static var roundEndsWhenWindow: JSONValue {
        .object([
            "tag": .string("RoundEnds"),
            "contents": .string("When"),
        ])
    }

    private static func roundTransitionTreacherySource(
        _ value: JSONValue?
    ) -> TreacheryID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("TreacherySource"),
              case let .string(raw)? = source["contents"]
        else { return nil }
        return TreacheryID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private static func roundTransitionAgendaSource(
        _ value: JSONValue?
    ) -> AgendaID? {
        guard case let .object(source)? = value,
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("AgendaSource"),
              let agendaID = roundTransitionAgendaID(source["contents"]),
              agendaID.rawValue.rawValue == roundTransitionAgendaCardCode
        else { return nil }
        return agendaID
    }

    private static func roundTransitionAgendaID(_ value: JSONValue?) -> AgendaID? {
        guard case let .string(raw)? = value else { return nil }
        return AgendaID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private static func roundTransitionInvestigatorID(
        _ value: JSONValue?
    ) -> InvestigatorID? {
        guard case let .string(raw)? = value,
              let code = strictCardCode(raw)
        else { return nil }
        return InvestigatorID(code)
    }

    private static func roundTransitionInvestigatorMessageContents(
        _ value: JSONValue, tag: String
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

    private static func investigatorTarget(_ investigatorID: InvestigatorID) -> JSONValue {
        .object([
            "tag": .string("InvestigatorTarget"),
            "contents": .string(investigatorID.rawValue.rawValue),
        ])
    }

    private static func isCanonicalInteger(
        _ value: JSONValue?, equalTo expected: Int64
    ) -> Bool {
        guard isCanonicalInteger(value),
              case let .number(number)? = value
        else { return false }
        return number.rawToken == String(expected)
    }
}
