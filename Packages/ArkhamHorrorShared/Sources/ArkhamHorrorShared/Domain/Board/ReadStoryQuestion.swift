import Foundation

/// `Arkham.Text.FlavorText`: a story beat's optional title and its ordered body content,
/// encoded with the backend's `flavor`-field prefix stripped (`Arkham/Json.hs`'s
/// `aesonOptions`).
///
/// `title` and every `I18nEntry.key` are literal i18n lookup keys, never rendered narrative
/// text on the wire (the pinned schema's own documentation: "it is never rendered narrative
/// text on the wire") — this domain type preserves them exactly as decoded, completely
/// losslessly, but never presents them directly: ``StoryNarrativeLocalization`` is this
/// client's sole narrow, fail-closed boundary that resolves a `FlavorText` into
/// human-readable presentation text (or `nil`, when no lawful resolution is possible),
/// rather than fabricating, translating, or otherwise inventing Arkham Horror LCG flavor
/// prose.
struct FlavorText: Sendable, Equatable, Hashable {
    let title: String?
    let body: [FlavorTextEntry]
}

/// Only the three `FlavorTextEntry` (`Arkham/Text.hs`) constructors the governed contract
/// slice actually exercises. Every other real constructor (`HeaderEntry`, `ModifyEntry`,
/// `CompositeEntry`, `ColumnEntry`, `CardEntry`, `TarotEntry`, `ChaosTokenEntry`,
/// `ChaosTokenMorphEntry`, `EntrySplit`) has no case here and fails the containing `Read`
/// question closed (see `BasicChoiceParser.parseFlavorTextEntry`) — never silently dropped
/// or normalized into one of these three.
indirect enum FlavorTextEntry: Sendable, Equatable, Hashable {
    case basic(text: String)
    /// `variables` is preserved losslessly and opaque (the schema itself only requires it
    /// be a JSON object) — this client never interprets or substitutes it.
    case i18n(key: String, variables: JSONValue)
    case list(items: [FlavorTextListItem])
}

/// `FlavorTextEntry`'s recursive `ListEntry` item, exactly mirroring the wire's
/// `{"entry": ..., "nested": [...]}` shape (no `tag` of its own).
struct FlavorTextListItem: Sendable, Equatable, Hashable {
    let entry: FlavorTextEntry
    let nested: [FlavorTextListItem]
}

/// The governed `Read` question's story payload: its flavor text plus the `Maybe [CardCode]`
/// cards the beat adds to play (`readCards`). `readCards` is always present on the wire as
/// either JSON `null` or an array — never omitted — matching Aeson's non-omitting `Maybe`
/// encoding.
struct ReadStoryContent: Sendable, Equatable, Hashable {
    let flavorText: FlavorText
    let readCards: [CardCode]?
}

extension BasicChoiceParser {
    /// Parses a governed `Read` question (`readQuestion` in
    /// `basic-choice-question.schema.json`): strict flavor text, the single governed
    /// `BasicReadChoices` semantic continue label (synthesized here as the question's sole
    /// index-0 `.continueReading` choice so it flows through the exact same
    /// choice-index-based submission/focus/authority path every other `BasicChoiceQuestion`
    /// already uses), and the required nullable `readCards`.
    static func parseReadQuestion(
        _ object: [String: JSONValue],
        rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard Set(object.keys) == ["tag", "flavorText", "readChoices", "readCards"],
              case let .object(flavorTextObject)? = object["flavorText"],
              let flavorText = parseFlavorText(flavorTextObject),
              let readChoicesValue = object["readChoices"],
              case let .object(readChoicesObject) = readChoicesValue,
              let continueMessages = parseBasicReadChoices(readChoicesObject),
              let readCards = parseReadCards(object["readCards"])
        else {
            return .updateRequired(tag: "Read")
        }
        let story = ReadStoryContent(flavorText: flavorText, readCards: readCards)
        let choice = BasicChoice(
            index: 0,
            rawValue: readChoicesValue,
            content: .continueReading(messages: continueMessages)
        )
        return .supported(
            BasicChoiceQuestion(kind: .read, choices: [choice], story: story, rawValue: rawValue)
        )
    }

    /// Requires the exact governed shape `BasicReadChoices [Label "$continue" []]`: a single
    /// continue-label element with an always-empty `messages` array. Any other
    /// `ReadChoices` tag (`BasicReadChoicesN`, `BasicReadChoicesUpToN`,
    /// `LeadInvestigatorMustDecide`) or any deviation of the single label's `label`/
    /// `messages` fields is an explicit unsupported value, never normalized into a continue.
    private static func parseBasicReadChoices(_ object: [String: JSONValue]) -> [JSONValue]? {
        guard Set(object.keys) == ["tag", "contents"],
              object["tag"] == .string("BasicReadChoices"),
              case let .array(contents)? = object["contents"],
              contents.count == 1,
              case let .object(label)? = contents.first,
              Set(label.keys) == ["tag", "label", "messages"],
              label["tag"] == .string("Label"),
              label["label"] == .string("$continue"),
              case let .array(messages)? = label["messages"],
              messages.isEmpty
        else { return nil }
        return messages
    }

    private static func parseFlavorText(_ object: [String: JSONValue]) -> FlavorText? {
        guard Set(object.keys) == ["title", "body"] else { return nil }
        let title: String?
        switch object["title"] {
        case let .string(text)?:
            title = text
        case .null?:
            title = nil
        default:
            return nil
        }
        guard case let .array(bodyValues)? = object["body"] else { return nil }
        var body: [FlavorTextEntry] = []
        body.reserveCapacity(bodyValues.count)
        for value in bodyValues {
            guard let entry = parseFlavorTextEntry(value) else { return nil }
            body.append(entry)
        }
        return FlavorText(title: title, body: body)
    }

    private static func parseFlavorTextEntry(_ value: JSONValue) -> FlavorTextEntry? {
        guard case let .object(object) = value, case let .string(tag)? = object["tag"] else {
            return nil
        }
        switch tag {
        case "BasicEntry":
            guard Set(object.keys) == ["tag", "text"],
                  case let .string(text)? = object["text"]
            else { return nil }
            return .basic(text: text)
        case "I18nEntry":
            guard Set(object.keys) == ["tag", "key", "variables"],
                  case let .string(key)? = object["key"],
                  !key.isEmpty,
                  case let .object(variables)? = object["variables"]
            else { return nil }
            return .i18n(key: key, variables: .object(variables))
        case "ListEntry":
            guard Set(object.keys) == ["tag", "list"],
                  case let .array(rawList)? = object["list"]
            else { return nil }
            var items: [FlavorTextListItem] = []
            items.reserveCapacity(rawList.count)
            for value in rawList {
                guard let item = parseFlavorTextListItem(value) else { return nil }
                items.append(item)
            }
            return .list(items: items)
        default:
            return nil
        }
    }

    private static func parseFlavorTextListItem(_ value: JSONValue) -> FlavorTextListItem? {
        guard case let .object(object) = value,
              Set(object.keys) == ["entry", "nested"],
              let entryValue = object["entry"],
              let entry = parseFlavorTextEntry(entryValue),
              case let .array(rawNested)? = object["nested"]
        else { return nil }
        var nested: [FlavorTextListItem] = []
        nested.reserveCapacity(rawNested.count)
        for value in rawNested {
            guard let item = parseFlavorTextListItem(value) else { return nil }
            nested.append(item)
        }
        return FlavorTextListItem(entry: entry, nested: nested)
    }

    /// Tri-state result distinguishing malformed input from the two legitimate `Maybe
    /// [CardCode]` values: `nil` means `readCards` was present but neither JSON `null` nor
    /// an array of strictly-validated card codes (the whole `Read` question becomes
    /// `.updateRequired`); `.some(nil)` is the wire's `null` (no cards); `.some(.some(_))`
    /// is the decoded array (never omitted, per the schema).
    private static func parseReadCards(_ value: JSONValue?) -> [CardCode]?? {
        switch value {
        case .null?:
            return .some(nil)
        case let .array(rawCodes)?:
            var codes: [CardCode] = []
            codes.reserveCapacity(rawCodes.count)
            for rawCode in rawCodes {
                guard case let .string(text) = rawCode, let code = strictCardCode(text) else {
                    return nil
                }
                codes.append(code)
            }
            return .some(codes)
        default:
            return nil
        }
    }
}
