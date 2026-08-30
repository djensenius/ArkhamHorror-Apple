import Foundation

enum BasicChoiceQuestionKind: String, Sendable {
    case chooseOne = "ChooseOne"
    case playerWindowChooseOne = "PlayerWindowChooseOne"
    case windowChooseOne = "WindowChooseOne"
    case read = "Read"
}

struct BasicChoiceAbility: Sendable, Equatable, Hashable {
    let investigatorID: InvestigatorID
    let cardCode: CardCode
    let rawAbility: JSONValue
    let windows: [JSONValue]
    let before: [JSONValue]
    let messages: [JSONValue]
}

enum BasicChoiceContent: Sendable, Equatable, Hashable {
    case gainResource(investigatorID: InvestigatorID, messages: [JSONValue])
    case drawCard(investigatorID: InvestigatorID, messages: [JSONValue])
    case endTurn(investigatorID: InvestigatorID, messages: [JSONValue])
    case investigate(BasicChoiceAbility)
    case continueReading(messages: [JSONValue])
    case chooseLocation(locationID: LocationID, messages: [JSONValue])
    case unsupported(tag: String?)
}

struct BasicChoice: Sendable, Equatable, Hashable, Identifiable {
    let index: Int
    let rawValue: JSONValue
    let content: BasicChoiceContent

    var id: Int {
        index
    }

    var isSupported: Bool {
        if case .unsupported = content {
            false
        } else {
            true
        }
    }

    var title: String {
        switch content {
        case .gainResource: "Gain a resource"
        case .drawCard: "Draw a card"
        case .endTurn: "End turn"
        case .investigate: "Investigate"
        case .continueReading: "Continue"
        case .chooseLocation: "Choose starting location"
        case .unsupported: "Update required"
        }
    }

    var systemImage: String {
        switch content {
        case .gainResource: "circle.fill"
        case .drawCard: "rectangle.stack"
        case .endTurn: "forward.end"
        case .investigate: "magnifyingglass"
        case .continueReading: "arrow.right.circle.fill"
        case .chooseLocation: "mappin.and.ellipse"
        case .unsupported: "exclamationmark.triangle"
        }
    }

    var ability: BasicChoiceAbility? {
        guard case let .investigate(ability) = content else { return nil }
        return ability
    }

    var locationID: LocationID? {
        guard case let .chooseLocation(locationID, _) = content else { return nil }
        return locationID
    }
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
        guard Set(object.keys) == ["tag", "choices"],
              case let .array(rawChoices)? = object["choices"],
              !rawChoices.isEmpty
        else {
            return .updateRequired(tag: tag)
        }
        let choices = rawChoices.enumerated().map { index, choice in
            BasicChoice(index: index, rawValue: choice, content: parseChoice(choice))
        }
        return .supported(
            BasicChoiceQuestion(kind: kind, choices: choices, story: nil, rawValue: value)
        )
    }

    private static func parseChoice(_ value: JSONValue) -> BasicChoiceContent {
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
        case "TargetLabel":
            return parseTargetLabel(object) ?? .unsupported(tag: tag)
        default:
            return .unsupported(tag: tag)
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

    private static func parseTargetLabel(_ object: [String: JSONValue]) -> BasicChoiceContent? {
        guard Set(object.keys) == ["tag", "target", "messages"],
              let messages = messages(object["messages"]),
              case let .object(target)? = object["target"],
              Set(target.keys) == ["tag", "contents"],
              target["tag"] == .string("LocationTarget"),
              case let .string(rawLocationID)? = target["contents"],
              let locationID = canonicalLocationID(rawLocationID)
        else { return nil }
        return .chooseLocation(locationID: locationID, messages: messages)
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
    /// client never executes or interprets engine messages.
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

    private static func isCanonicalInteger(_ value: JSONValue?) -> Bool {
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

private extension Character {
    var isASCIIWholeNumber: Bool {
        wholeNumberValue != nil && unicodeScalars.count == 1
            && unicodeScalars.first.map { (48 ... 57).contains($0.value) } == true
    }
}

struct BasicChoiceAnswer: Sendable, Equatable {
    let choice: Int
    let playerID: PlayerID
    let questionVersion: Int
}

extension BasicChoiceAnswer: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    private enum ContentsKeys: String, CodingKey {
        case choice
        case playerID = "playerId"
        case questionVersion
    }

    init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(root) = value,
              Set(root.keys) == ["tag", "contents"],
              root["tag"] == .string("Answer"),
              case let .object(contents)? = root["contents"],
              Set(contents.keys) == ["choice", "playerId", "questionVersion"],
              let choice = Self.nonNegativeInteger(contents["choice"]),
              let questionVersion = Self.nonNegativeInteger(contents["questionVersion"]),
              case let .string(playerText)? = contents["playerId"],
              let playerKey = Identifier<PlayerIDTag>(
                  codingKey: AnyCodingKey(stringValue: playerText)
              )
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid Answer envelope")
            )
        }
        self.choice = choice
        playerID = playerKey
        self.questionVersion = questionVersion
    }

    func encode(to encoder: any Encoder) throws {
        guard choice >= 0, questionVersion >= 0 else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Answer integers must be non-negative"
                )
            )
        }
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode("Answer", forKey: .tag)
        var contents = root.nestedContainer(keyedBy: ContentsKeys.self, forKey: .contents)
        try contents.encode(choice, forKey: .choice)
        try contents.encode(playerID, forKey: .playerID)
        try contents.encode(questionVersion, forKey: .questionVersion)
    }

    private static func nonNegativeInteger(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.sign == .plus,
              let raw = number.rawToken,
              raw.allSatisfy(\.isASCIIWholeNumber),
              raw == "0" || raw.first != "0",
              let integer = Int(raw),
              integer >= 0
        else { return nil }
        return integer
    }
}
