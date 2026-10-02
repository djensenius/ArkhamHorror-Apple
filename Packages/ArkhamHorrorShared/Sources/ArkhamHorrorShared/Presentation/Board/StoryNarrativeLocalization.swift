import Foundation

/// A fully rendered story. It is created only after every title and body entry has resolved.
struct ResolvedStory: Sendable, Equatable {
    let title: String?
    let body: [ResolvedStoryEntry]
    let degradedReason: StoryUnavailableReason?

    init(
        title: String?,
        body: [ResolvedStoryEntry],
        degradedReason: StoryUnavailableReason? = nil
    ) {
        self.title = title
        self.body = body
        self.degradedReason = degradedReason
    }
}

/// A safe story entry. Catalog-backed entries retain their structured native render tree;
/// flavor-only formatting retains enough structure for native rendering while degrading
/// image-like entries to readable server-provided labels.
indirect enum ResolvedStoryEntry: Sendable, Equatable {
    case text(String)
    case nodes([StoryNode])
    case heading(level: FlavorTextHeadingLevel, nodes: [StoryNode])
    case modified(modifiers: [FlavorTextModifier], entry: ResolvedStoryEntry)
    case composite(entries: [ResolvedStoryEntry])
    case columns(entries: [ResolvedStoryEntry])
    case list(items: [ResolvedStoryListItem])
    case cardReference(cardCode: CardCode, imageModifiers: [FlavorTextImageModifier])
    case tarotReference(arcana: String)
    case chaosTokenReference(face: ChaosTokenFace)
    case chaosTokenMorph(from: ChaosTokenFace, target: ChaosTokenFace)
    case divider
}

struct ResolvedStoryListItem: Sendable, Equatable {
    let entry: ResolvedStoryEntry
    let nested: [ResolvedStoryListItem]
}

/// The one result every prompt surface, focus graph, accessibility hint, and sender shares.
enum StoryResolution: Sendable, Equatable {
    case resolved(ResolvedStory)
    case unavailable(StoryUnavailableReason)

    var story: ResolvedStory? {
        guard case let .resolved(story) = self else { return nil }
        return story
    }

    var unavailableReason: StoryUnavailableReason? {
        switch self {
        case let .unavailable(reason):
            reason
        case let .resolved(story):
            story.degradedReason
        }
    }

    var isResolved: Bool {
        if case .resolved = self {
            return true
        }
        return false
    }
}

/// Resolves `FlavorText` without ever rendering a raw i18n key or a partial story.
enum StoryNarrativeLocalization {
    /// Generic application chrome may remain available even before a deployment advertises a
    /// catalog. Scenario and campaign narrative is never guessed or hardcoded here.
    static let chromeVocabulary: [String: String] = [
        "continue": "Continue",
        "setup": "Setup",
    ]

    /// Production resolution. One `LocaleCatalogResolver` value captures one immutable
    /// snapshot, so title and body cannot observe different revisions.
    static func resolve(
        _ flavorText: FlavorText,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason?
    ) -> StoryResolution {
        if resolver == nil, catalogUnavailability == .loading {
            return .unavailable(.loading)
        }
        switch resolveProductionStory(
            flavorText,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability ?? .catalog(.notAdvertised)
        ) {
        case let .success(story):
            return .resolved(story)
        case let .failure(reason):
            return .unavailable(reason)
        }
    }

    /// The synthetic-vocabulary seam used by pre-catalog tests. Production callers use
    /// `resolve(_:resolver:catalogUnavailability:)` so narrative keys can only come from a
    /// verified deployment-owned snapshot.
    static func resolvedStory(
        for flavorText: FlavorText, vocabulary: [String: String] = chromeVocabulary
    ) -> ResolvedStory? {
        guard let title = resolvedStaticTitle(flavorText.title, vocabulary: vocabulary) else {
            return nil
        }
        var body: [ResolvedStoryEntry] = []
        body.reserveCapacity(flavorText.body.count)
        for entry in flavorText.body {
            guard let resolved = resolvedStaticEntry(entry, vocabulary: vocabulary) else {
                return nil
            }
            body.append(resolved)
        }
        return ResolvedStory(title: title, body: body)
    }
}

// MARK: - Synthetic vocabulary resolution

extension StoryNarrativeLocalization {
    static func resolvedStaticTitle(
        _ rawTitle: String?, vocabulary: [String: String]
    ) -> String?? {
        guard let rawTitle else { return .some(nil) }
        guard let resolved = resolvedStaticLiteralOrKey(rawTitle, vocabulary: vocabulary) else {
            return nil
        }
        return .some(resolved)
    }

    static func resolvedStaticLiteralOrKey(
        _ rawValue: String, vocabulary: [String: String]
    ) -> String? {
        guard rawValue.hasPrefix("$") else { return rawValue }
        let key = String(rawValue.dropFirst())
        return vocabulary[key] ?? key
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func resolvedStaticEntry(
        _ entry: FlavorTextEntry, vocabulary: [String: String]
    ) -> ResolvedStoryEntry? {
        switch entry {
        case let .basic(text):
            return .text(resolvedStaticLiteralOrKey(text, vocabulary: vocabulary) ?? text)
        case let .header(level, key):
            return .heading(level: level, nodes: [.text(vocabulary[key] ?? key)])
        case let .i18n(key, variables):
            guard let template = vocabulary[key] else {
                return .text(readableServerFallback(key: key, variables: variables))
            }
            guard let substituted = substituteVariables(template, variables: variables) else {
                return nil
            }
            return .text(substituted)
        case let .modify(modifiers, entry):
            guard let resolved = resolvedStaticEntry(entry, vocabulary: vocabulary) else {
                return nil
            }
            return .modified(modifiers: modifiers, entry: resolved)
        case let .composite(entries):
            return resolvedStaticEntries(entries, vocabulary: vocabulary).map {
                .composite(entries: $0)
            }
        case let .column(entries):
            return resolvedStaticEntries(entries, vocabulary: vocabulary).map {
                .columns(entries: $0)
            }
        case let .list(items):
            var resolvedItems: [ResolvedStoryListItem] = []
            resolvedItems.reserveCapacity(items.count)
            for item in items {
                guard let resolvedItem = resolvedStaticListItem(item, vocabulary: vocabulary) else {
                    return nil
                }
                resolvedItems.append(resolvedItem)
            }
            return .list(items: resolvedItems)
        case let .card(cardCode, imageModifiers):
            return .cardReference(cardCode: cardCode, imageModifiers: imageModifiers)
        case let .tarot(arcana):
            return .tarotReference(arcana: arcana)
        case let .chaosToken(face):
            return .chaosTokenReference(face: face)
        case let .chaosTokenMorph(from, target):
            return .chaosTokenMorph(from: from, target: target)
        case .split:
            return .divider
        case let .unknown(tag, text):
            return .text(readableUnknownEntry(tag: tag, text: text))
        }
    }

    static func resolvedStaticEntries(
        _ entries: [FlavorTextEntry], vocabulary: [String: String]
    ) -> [ResolvedStoryEntry]? {
        var resolvedEntries: [ResolvedStoryEntry] = []
        resolvedEntries.reserveCapacity(entries.count)
        for entry in entries {
            guard let resolved = resolvedStaticEntry(entry, vocabulary: vocabulary) else {
                return nil
            }
            resolvedEntries.append(resolved)
        }
        return resolvedEntries
    }

    static func resolvedStaticListItem(
        _ item: FlavorTextListItem, vocabulary: [String: String]
    ) -> ResolvedStoryListItem? {
        guard let entry = resolvedStaticEntry(item.entry, vocabulary: vocabulary) else {
            return nil
        }
        var nested: [ResolvedStoryListItem] = []
        nested.reserveCapacity(item.nested.count)
        for child in item.nested {
            guard let resolved = resolvedStaticListItem(child, vocabulary: vocabulary) else {
                return nil
            }
            nested.append(resolved)
        }
        return ResolvedStoryListItem(entry: entry, nested: nested)
    }

    static func substituteVariables(_ template: String, variables: JSONValue) -> String? {
        guard case let .object(variableObject) = variables else { return nil }
        var result = ""
        var remainder = Substring(template)
        while let openBrace = remainder.firstIndex(of: "{") {
            result += remainder[remainder.startIndex ..< openBrace]
            let afterOpen = remainder.index(after: openBrace)
            guard let closeBrace = remainder[afterOpen...].firstIndex(of: "}") else {
                return nil
            }
            let identifier = String(remainder[afterOpen ..< closeBrace])
            guard isStaticPlaceholderIdentifier(identifier),
                  let value = variableObject[identifier],
                  let stringValue = stringifyVariable(value)
            else {
                return nil
            }
            result += stringValue
            remainder = remainder[remainder.index(after: closeBrace)...]
        }
        result += remainder
        return result
    }

    static func stringifyVariable(_ value: JSONValue) -> String? {
        switch value {
        case let .string(text):
            text
        case let .number(number):
            number.description
        case .null, .bool, .array, .object:
            nil
        }
    }

    static func readableUnknownEntry(tag: String, text: String?) -> String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "Unsupported story entry: \(tag)"
    }

    static func readableServerFallback(key: String, variables: JSONValue) -> String {
        guard case let .object(object) = variables, !object.isEmpty else { return key }
        let pairs = object.keys.sorted().map { key in
            "\(key): \(readableJSONValue(object[key] ?? .null))"
        }
        return "\(key) (\(pairs.joined(separator: ", ")))"
    }

    static func readableJSONValue(_ value: JSONValue) -> String {
        switch value {
        case .null:
            "null"
        case let .bool(flag):
            flag ? "true" : "false"
        case let .number(number):
            number.description
        case let .string(text):
            text
        case let .array(values):
            "[" + values.map(readableJSONValue).joined(separator: ", ") + "]"
        case let .object(object):
            "{" + object.keys.sorted().map { key in
                "\(key): \(readableJSONValue(object[key] ?? .null))"
            }.joined(separator: ", ") + "}"
        }
    }

    static func isStaticPlaceholderIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first,
              first == 0x5F || (0x41 ... 0x5A).contains(first)
              || (0x61 ... 0x7A).contains(first)
        else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            $0 == 0x5F || (0x41 ... 0x5A).contains($0) || (0x61 ... 0x7A).contains($0)
                || (0x30 ... 0x39).contains($0)
        }
    }
}
