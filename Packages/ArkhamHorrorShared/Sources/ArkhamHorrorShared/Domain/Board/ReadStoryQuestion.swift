import Foundation

/// `Arkham.Text.FlavorText`: a story beat's optional title and its ordered body content,
/// encoded with the backend's `flavor`-field prefix stripped (`Arkham/Json.hs`'s
/// `aesonOptions`).
///
/// `title`, every `HeaderEntry.key`, and every `I18nEntry.key` are catalog lookup keys
/// when a verified catalog is available. They are still server-authored story data, so this
/// domain type preserves every `Arkham.Text.FlavorTextEntry` constructor the backend can
/// encode and lets presentation fall back to readable server-provided values instead of
/// treating story formatting as an app-update boundary.
struct FlavorText: Sendable, Equatable, Hashable {
    let title: String?
    let body: [FlavorTextEntry]
}

/// `HeaderEntry.level` is an unconstrained Haskell `Int`; web renders level 1 as h1 and
/// every other level as a smaller heading, so Apple keeps the integer rather than closing
/// over a historical subset.
struct FlavorTextHeadingLevel: RawRepresentable, Sendable, Equatable, Hashable {
    let rawValue: Int

    static let level1 = FlavorTextHeadingLevel(rawValue: 1)
    static let level3 = FlavorTextHeadingLevel(rawValue: 3)
}

enum FlavorTextModifier: String, Sendable, Equatable, Hashable, CaseIterable {
    case blueEntry = "BlueEntry"
    case greenEntry = "GreenEntry"
    case borderedEntry = "BorderedEntry"
    case redEntry = "RedEntry"
    case rightAligned = "RightAligned"
    case plainText = "PlainText"
    case invalidEntry = "InvalidEntry"
    case validEntry = "ValidEntry"
    case centeredEntry = "CenteredEntry"
    case resolutionEntry = "ResolutionEntry"
    case checkpointEntry = "CheckpointEntry"
    case interludeEntry = "InterludeEntry"
    case nestedEntry = "NestedEntry"
    case noUnderline = "NoUnderline"
    case codexEntry = "CodexEntry"
    case hauntedEntry = "HauntedEntry"
    case tokenRevealEntry = "TokenRevealEntry"
    case byDifficultyEntry = "ByDifficultyEntry"
}

enum FlavorTextImageModifier: String, Sendable, Equatable, Hashable, CaseIterable {
    case removeImage = "RemoveImage"
    case selectImage = "SelectImage"
    case smallImage = "SmallImage"
}

/// Every `FlavorTextEntry` constructor currently emitted by `Arkham.Text`.
indirect enum FlavorTextEntry: Sendable, Equatable, Hashable {
    case basic(text: String)
    case header(level: FlavorTextHeadingLevel, key: String)
    /// `variables` is preserved losslessly and opaque unless a verified catalog template
    /// requests substitution.
    case i18n(key: String, variables: JSONValue)
    case modify(modifiers: [FlavorTextModifier], entry: FlavorTextEntry)
    case composite(entries: [FlavorTextEntry])
    case column(entries: [FlavorTextEntry])
    case list(items: [FlavorTextListItem])
    case card(cardCode: CardCode, imageModifiers: [FlavorTextImageModifier])
    case tarot(arcana: String)
    case chaosToken(face: ChaosTokenFace)
    case chaosTokenMorph(from: ChaosTokenFace, target: ChaosTokenFace)
    case split
    case unknown(tag: String, text: String?)
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
    /// `basic-choice-question.schema.json`): flavor text preserved for readable rendering,
    /// the single governed `BasicReadChoices` semantic continue label (synthesized here as
    /// the question's sole index-0 `.continueReading` choice so it flows through the exact same
    /// choice-index-based submission/focus/authority path every other `BasicChoiceQuestion`
    /// already uses), and the required nullable `readCards`.
    static func parseReadQuestion(
        _ object: [String: JSONValue],
        rawValue: JSONValue
    ) -> BasicChoiceQuestionState {
        guard case let .object(flavorTextObject)? = object["flavorText"],
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

    // swiftlint:disable:next cyclomatic_complexity
    private static func parseFlavorTextEntry(_ value: JSONValue) -> FlavorTextEntry? {
        guard case let .object(object) = value, case let .string(tag)? = object["tag"] else {
            return nil
        }
        switch tag {
        case "BasicEntry":
            return parseBasicFlavorTextEntry(object)
        case "HeaderEntry":
            return parseHeaderFlavorTextEntry(object)
        case "I18nEntry":
            return parseI18nFlavorTextEntry(object)
        case "ModifyEntry":
            return parseModifyFlavorTextEntry(object)
        case "CompositeEntry":
            return parseCompositeFlavorTextEntry(object)
        case "ColumnEntry":
            return parseColumnFlavorTextEntry(object)
        case "ListEntry":
            return parseListFlavorTextEntry(object)
        case "CardEntry":
            return parseCardFlavorTextEntry(object)
        case "TarotEntry":
            return parseTarotFlavorTextEntry(object)
        case "ChaosTokenEntry":
            return parseChaosTokenFlavorTextEntry(object)
        case "ChaosTokenMorphEntry":
            return parseChaosTokenMorphFlavorTextEntry(object)
        case "EntrySplit":
            return .split
        default:
            return parseUnknownFlavorTextEntry(object, tag: tag)
        }
    }

    private static func parseBasicFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .string(text)? = object["text"] else { return nil }
        return .basic(text: text)
    }

    private static func parseHeaderFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard let level = parseFlavorTextHeadingLevel(object["level"]),
              case let .string(key)? = object["key"]
        else { return nil }
        return .header(level: level, key: key)
    }

    private static func parseI18nFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .string(key)? = object["key"],
              case let .object(variables)? = object["variables"]
        else { return nil }
        return .i18n(key: key, variables: .object(variables))
    }

    private static func parseModifyFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .array(rawModifiers)? = object["modifiers"],
              let entryValue = object["entry"],
              let entry = parseFlavorTextEntry(entryValue)
        else { return nil }
        var modifiers: [FlavorTextModifier] = []
        modifiers.reserveCapacity(rawModifiers.count)
        for rawModifier in rawModifiers {
            guard case let .string(text) = rawModifier else { continue }
            if let modifier = FlavorTextModifier(rawValue: text) {
                modifiers.append(modifier)
            }
        }
        return .modify(modifiers: modifiers, entry: entry)
    }

    private static func parseCompositeFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        parseEntryArray(object, tag: "CompositeEntry").map { .composite(entries: $0) }
    }

    private static func parseColumnFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        parseEntryArray(object, tag: "ColumnEntry").map { .column(entries: $0) }
    }

    private static func parseEntryArray(
        _ object: [String: JSONValue], tag: String
    ) -> [FlavorTextEntry]? {
        guard object["tag"] == .string(tag),
              case let .array(rawEntries)? = object["entries"]
        else { return nil }
        var entries: [FlavorTextEntry] = []
        entries.reserveCapacity(rawEntries.count)
        for value in rawEntries {
            guard let entry = parseFlavorTextEntry(value) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    private static func parseListFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .array(rawList)? = object["list"] else { return nil }
        var items: [FlavorTextListItem] = []
        items.reserveCapacity(rawList.count)
        for value in rawList {
            guard let item = parseFlavorTextListItem(value) else { return nil }
            items.append(item)
        }
        return .list(items: items)
    }

    private static func parseCardFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .string(rawCardCode)? = object["cardCode"],
              let cardCode = strictCardCode(rawCardCode),
              case let .array(rawModifiers)? = object["imageModifiers"]
        else { return nil }
        var modifiers: [FlavorTextImageModifier] = []
        modifiers.reserveCapacity(rawModifiers.count)
        for rawModifier in rawModifiers {
            guard case let .string(text) = rawModifier else { continue }
            if let modifier = FlavorTextImageModifier(rawValue: text) {
                modifiers.append(modifier)
            }
        }
        return .card(cardCode: cardCode, imageModifiers: modifiers)
    }

    private static func parseTarotFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .string(arcana)? = object["tarot"] else { return nil }
        return .tarot(arcana: arcana)
    }

    private static func parseChaosTokenFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .string(face)? = object["chaosTokenFace"] else { return nil }
        return .chaosToken(face: ChaosTokenFace(face))
    }

    private static func parseChaosTokenMorphFlavorTextEntry(
        _ object: [String: JSONValue]
    ) -> FlavorTextEntry? {
        guard case let .string(from)? = object["morphFrom"],
              case let .string(target)? = object["morphTo"]
        else { return nil }
        return .chaosTokenMorph(from: ChaosTokenFace(from), target: ChaosTokenFace(target))
    }

    private static func parseUnknownFlavorTextEntry(
        _ object: [String: JSONValue], tag: String
    ) -> FlavorTextEntry {
        .unknown(tag: tag, text: readableUnknownFlavorText(in: object))
    }

    private static func readableUnknownFlavorText(in object: [String: JSONValue]) -> String? {
        let values = object.keys.sorted().compactMap { key -> String? in
            guard key != "tag", case let .string(text)? = object[key] else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " ")
    }

    private static func parseFlavorTextHeadingLevel(
        _ value: JSONValue?
    ) -> FlavorTextHeadingLevel? {
        guard case let .number(number)? = value,
              let magnitude = number.wholeNumberMagnitude,
              let parsedMagnitude = Int(magnitude)
        else { return nil }
        let level = number.sign == .minus ? -parsedMagnitude : parsedMagnitude
        return FlavorTextHeadingLevel(rawValue: level)
    }

    private static func parseFlavorTextListItem(_ value: JSONValue) -> FlavorTextListItem? {
        guard case let .object(object) = value,
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
