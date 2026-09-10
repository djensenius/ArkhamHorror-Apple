import Foundation

enum BasicChoiceQuestionKind: String, Sendable {
    case chooseOne = "ChooseOne"
    case chooseOneAtATime = "ChooseOneAtATime"
    case playerWindowChooseOne = "PlayerWindowChooseOne"
    case windowChooseOne = "WindowChooseOne"
    case read = "Read"
    case questionWithSource = "QuestionWithSource"
}

struct BasicChoiceQuestion: Sendable, Equatable, Hashable {
    let kind: BasicChoiceQuestionKind
    let choices: [BasicChoice]
    /// The `Read` question's story payload (flavor text plus any cards it adds to play).
    /// Always `nil` for every other kind; always non-nil (and internally consistent with
    /// `choices`, a single synthesized `.continueReading` entry) when `kind == .read`.
    let story: ReadStoryContent?
    let rawValue: JSONValue
}

enum BasicChoiceQuestionState: Sendable, Equatable, Hashable {
    case supported(BasicChoiceQuestion)
    case updateRequired(tag: String?)

    var supportedQuestion: BasicChoiceQuestion? {
        guard case let .supported(question) = self else { return nil }
        return question
    }
}

struct BasicChoiceQuestionPayload: Sendable, Equatable, Hashable {
    let rawValue: JSONValue
    let state: BasicChoiceQuestionState

    var supportedQuestion: BasicChoiceQuestion? {
        guard case let .supported(question) = state else { return nil }
        return question
    }

    var isUpdateRequired: Bool {
        if case .updateRequired = state {
            true
        } else {
            false
        }
    }
}

extension BasicChoiceQuestionPayload: Codable {
    init(from decoder: any Decoder) throws {
        let rawValue = try JSONValue(from: decoder)
        self.rawValue = rawValue
        state = BasicChoiceParser.parseQuestion(rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

enum BasicChoiceParser {
    private static let doneWithMulliganLabel = "$label.doneWithMulligan"

    static func parseQuestion(_ value: JSONValue) -> BasicChoiceQuestionState {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else {
            return .updateRequired(tag: nil)
        }
        guard let kind = BasicChoiceQuestionKind(rawValue: tag) else {
            return .updateRequired(tag: tag)
        }
        if kind == .read {
            return parseReadQuestion(object, rawValue: value)
        }
        if kind == .chooseOneAtATime {
            return parseEnemyAttackQuestion(object, rawValue: value)
        }
        if kind == .questionWithSource {
            return parseEnemyAttackDamageAssignmentQuestion(object, rawValue: value)
        }
        guard Set(object.keys) == ["tag", "choices"],
              case let .array(rawChoices)? = object["choices"],
              !rawChoices.isEmpty
        else {
            return .updateRequired(tag: tag)
        }
        let parsedChoices = rawChoices.enumerated().map { index, choice in
            BasicChoice(
                index: index, rawValue: choice,
                content: parseChoice(choice, kind: kind, index: index)
            )
        }
        let choices = contextualizeHandCardChoices(parsedChoices, kind: kind)
        return .supported(
            BasicChoiceQuestion(kind: kind, choices: choices, story: nil, rawValue: value)
        )
    }

    private static func parseChoice(
        _ value: JSONValue, kind: BasicChoiceQuestionKind, index: Int
    ) -> BasicChoiceContent {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else {
            return .unsupported(tag: nil)
        }
        switch tag {
        case "ComponentLabel":
            return parseComponentLabel(object) ?? .unsupported(tag: tag)
        case "EndTurnButton":
            return parseEndTurn(object) ?? .unsupported(tag: tag)
        case "AbilityLabel":
            return parseAbilityLabel(object) ?? .unsupported(tag: tag)
        case "Label":
            return parseLabel(object) ?? .unsupported(tag: tag)
        case "TargetLabel":
            return parseTargetLabel(object, kind: kind, index: index) ?? .unsupported(tag: tag)
        case "SkipTriggersButton":
            return parseInvestigatorControl(object, tag: tag).map {
                .skipTriggers(investigatorID: $0)
            } ?? .unsupported(tag: tag)
        case "StartSkillTestButton":
            return parseInvestigatorControl(object, tag: tag).map {
                .startSkillTest(investigatorID: $0)
            } ?? .unsupported(tag: tag)
        case "SkillTestApplyResultsButton":
            return Set(object.keys) == ["tag"] ? .applySkillTestResults : .unsupported(tag: tag)
        default:
            return .unsupported(tag: tag)
        }
    }

    private static func contextualizeHandCardChoices(
        _ choices: [BasicChoice], kind: BasicChoiceQuestionKind
    ) -> [BasicChoice] {
        let purpose: BasicChoiceHandCardPurpose = if choices.contains(where: {
            if case .finishMulligan = $0.content {
                true
            } else {
                false
            }
        }) {
            .replace
        } else if choices.contains(where: {
            if case .startSkillTest = $0.content {
                true
            } else {
                false
            }
        }) {
            .commit
        } else if kind == .playerWindowChooseOne || kind == .windowChooseOne {
            .play
        } else {
            .choose
        }
        return choices.map { choice in
            guard case let .chooseHandCard(cardID, _, messages) = choice.content else {
                return choice
            }
            return BasicChoice(
                index: choice.index,
                rawValue: choice.rawValue,
                content: .chooseHandCard(
                    cardID: cardID, purpose: purpose, messages: messages
                )
            )
        }
    }

    private static func parseComponentLabel(
        _ object: [String: JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(object.keys) == ["tag", "component", "messages"],
              let messages = messages(object["messages"]),
              case let .object(component)? = object["component"],
              case let .string(tag)? = component["tag"]
        else { return nil }
        switch tag {
        case "InvestigatorComponent":
            guard Set(component.keys) == ["tag", "investigatorId", "tokenType"],
                  component["tokenType"] == .string("ResourceToken"),
                  let investigatorID = investigatorID(component["investigatorId"])
            else { return nil }
            return .gainResource(investigatorID: investigatorID, messages: messages)
        case "InvestigatorDeckComponent":
            guard Set(component.keys) == ["tag", "investigatorId"],
                  let investigatorID = investigatorID(component["investigatorId"])
            else { return nil }
            return .drawCard(investigatorID: investigatorID, messages: messages)
        default:
            return nil
        }
    }

    private static func parseEndTurn(_ object: [String: JSONValue]) -> BasicChoiceContent? {
        guard Set(object.keys) == ["tag", "investigatorId", "messages"],
              let investigatorID = investigatorID(object["investigatorId"]),
              let messages = messages(object["messages"])
        else { return nil }
        return .endTurn(investigatorID: investigatorID, messages: messages)
    }

    private static func parseInvestigatorControl(
        _ object: [String: JSONValue], tag: String
    ) -> InvestigatorID? {
        guard Set(object.keys) == ["tag", "investigatorId"],
              object["tag"] == .string(tag)
        else { return nil }
        return investigatorID(object["investigatorId"])
    }

    private static func parseLabel(_ object: [String: JSONValue]) -> BasicChoiceContent? {
        guard Set(object.keys) == ["tag", "label", "messages"],
              object["label"] == .string(doneWithMulliganLabel),
              let messages = messages(object["messages"])
        else { return nil }
        return .finishMulligan(label: doneWithMulliganLabel, messages: messages)
    }

    private static func parseTargetLabel(
        _ object: [String: JSONValue], kind: BasicChoiceQuestionKind, index: Int
    ) -> BasicChoiceContent? {
        if let draw = parseEncounterDeckDraw(object, kind: kind, index: index) {
            return draw
        }
        guard Set(object.keys) == ["tag", "target", "messages"],
              let messages = messages(object["messages"]),
              case let .object(target)? = object["target"],
              Set(target.keys) == ["tag", "contents"]
        else { return nil }
        switch target["tag"] {
        case .string("LocationTarget"):
            guard case let .string(rawLocationID)? = target["contents"],
                  let locationID = canonicalLocationID(rawLocationID)
            else { return nil }
            return .chooseLocation(locationID: locationID, messages: messages)
        case .string("CardIdTarget"):
            guard case let .string(rawCardID)? = target["contents"],
                  let cardID = canonicalCardID(rawCardID)
            else { return nil }
            return .chooseHandCard(cardID: cardID, purpose: .choose, messages: messages)
        default:
            return nil
        }
    }

    private static func parseAbilityLabel(
        _ object: [String: JSONValue]
    ) -> BasicChoiceContent? {
        guard Set(object.keys) == [
            "tag", "investigatorId", "ability", "windows", "before", "messages",
        ],
            let investigatorID = investigatorID(object["investigatorId"]),
            case let .object(ability)? = object["ability"],
            case .object? = ability["source"],
            case let .string(cardCodeText)? = ability["cardCode"],
            let cardCode = strictCardCode(cardCodeText),
            isCanonicalInteger(ability["index"]),
            case let .object(type)? = ability["type"],
            case .string("ActionAbility")? = type["tag"],
            case let .object(actions)? = type["actions"],
            case .string("SingleAction")? = actions["tag"],
            case .string("Investigate")? = actions["contents"],
            case let .array(windows)? = object["windows"],
            let before = messages(object["before"]),
            let messages = messages(object["messages"])
        else { return nil }
        return .investigate(BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: cardCode,
            rawAbility: object["ability"] ?? .null,
            windows: windows,
            before: before,
            messages: messages
        ))
    }

    /// Strict "engine message" array validator, shared by every `ComponentLabel`/
    /// `EndTurnButton`/`AbilityLabel` (`before` and `messages`)/`TargetLabel` path. Backend
    /// 0.1.22's `Message` schema requires every array element to be a tagged constructor
    /// object -- a bare scalar, `null`, or an object missing/emptying its `tag` cannot
    /// stand in for one (see `manifest.json`'s `message` schemaBranch negatives). Only the
    /// `tag` field's shape is validated here; every other field (including an entirely
    /// opaque `contents`) is returned completely unmodified and lossless, since this
    /// client never executes engine messages. The encounter-deck choice separately
    /// validates its closed nested draw contract before granting action authority.
    private static func messages(_ value: JSONValue?) -> [JSONValue]? {
        guard case let .array(values)? = value, values.allSatisfy(isValidMessage) else {
            return nil
        }
        return values
    }

    private static func isValidMessage(_ value: JSONValue) -> Bool {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else { return false }
        return !tag.isEmpty
    }

    private static func investigatorID(_ value: JSONValue?) -> InvestigatorID? {
        guard case let .string(raw)? = value, let code = strictCardCode(raw) else { return nil }
        return InvestigatorID(code)
    }

    /// Reused (not `private`) by `ReadStoryQuestion.swift`'s `readCards` parsing, so both
    /// value-position card-code fields share exactly one strict validation rule.
    static func strictCardCode(_ raw: String) -> CardCode? {
        CardCode(codingKey: AnyCodingKey(stringValue: raw))
    }

    /// Strict canonical-lowercase UUID text, matching the `Identifier<Tag>
    /// .init?(codingKey:)` map-key rule (`BoardIdentifiers.swift`) rather than plain
    /// `Decodable`'s case-insensitive `UUID(uuidString:)` path, so an uppercase-rendered
    /// location ID is rejected here exactly as the pinned contract's `uuid.schema.json`
    /// requires -- not silently accepted as an alias of the same value.
    private static func canonicalLocationID(_ raw: String) -> LocationID? {
        LocationID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private static func canonicalCardID(_ raw: String) -> WireCardID? {
        WireCardID(codingKey: AnyCodingKey(stringValue: raw))
    }

    /// Shared with exact closed parsers that additionally compare the retained token to a
    /// governed integer value.
    static func isCanonicalInteger(_ value: JSONValue?) -> Bool {
        guard case let .number(number)? = value,
              number.sign == .plus,
              let token = number.rawToken
        else { return false }
        return !token.isEmpty
            && token.allSatisfy(\.isASCIIWholeNumber)
            && (token == "0" || token.first != "0")
            && Int64(token) != nil
    }
}

extension Character {
    var isASCIIWholeNumber: Bool {
        wholeNumberValue != nil && unicodeScalars.count == 1
            && unicodeScalars.first.map { (48 ... 57).contains($0.value) } == true
    }
}
