import Foundation

/// A fully rendered story. It is created only after every title and body entry has resolved.
struct ResolvedStory: Sendable, Equatable {
    let title: String?
    let body: [ResolvedStoryEntry]
}

/// A safe story entry. Catalog-backed entries retain their structured native render tree.
indirect enum ResolvedStoryEntry: Sendable, Equatable {
    case text(String)
    case nodes([StoryNode])
    case list(items: [ResolvedStoryListItem])
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
        guard case let .unavailable(reason) = self else { return nil }
        return reason
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
        switch resolveProductionStory(
            flavorText,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability ?? .catalog(.notAdvertised)
        ) {
        case let .success(story):
            .resolved(story)
        case let .failure(reason):
            .unavailable(reason)
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

// MARK: - Production catalog resolution

extension StoryNarrativeLocalization {
    static func resolveProductionStory(
        _ flavorText: FlavorText,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStory, StoryUnavailableReason> {
        switch resolveProductionTitle(
            flavorText.title,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(title):
            var body: [ResolvedStoryEntry] = []
            body.reserveCapacity(flavorText.body.count)
            for entry in flavorText.body {
                switch resolveProductionEntry(
                    entry,
                    resolver: resolver,
                    catalogUnavailability: catalogUnavailability
                ) {
                case let .success(resolved):
                    body.append(resolved)
                case let .failure(reason):
                    return .failure(reason)
                }
            }
            return .success(ResolvedStory(title: title, body: body))
        }
    }

    static func resolveProductionTitle(
        _ rawTitle: String?,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<String?, StoryUnavailableReason> {
        guard let rawTitle else { return .success(nil) }
        guard rawTitle.hasPrefix("$") else { return .success(rawTitle) }
        switch resolveKey(
            String(rawTitle.dropFirst()),
            variables: .object([:]),
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(nodes):
            guard !nodes.contains(where: \.losesInstructionWhenFlattened) else {
                return .failure(.unsupportedEntry)
            }
            return .success(nodes.map(\.plainText).joined())
        }
    }

    static func resolveProductionEntry(
        _ entry: FlavorTextEntry,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStoryEntry, StoryUnavailableReason> {
        switch entry {
        case let .basic(text):
            guard text.hasPrefix("$") else { return .success(.text(text)) }
            let key = String(text.dropFirst())
            if let chrome = chromeVocabulary[key] {
                return .success(.text(chrome))
            }
            return resolveKey(
                key,
                variables: .object([:]),
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map(ResolvedStoryEntry.nodes)
        case let .i18n(key, variables):
            if let chrome = chromeVocabulary[key] {
                guard let text = substituteVariables(chrome, variables: variables) else {
                    return .failure(.missingVariable)
                }
                return .success(.text(text))
            }
            return resolveKey(
                key,
                variables: variables,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map(ResolvedStoryEntry.nodes)
        case let .list(items):
            var resolvedItems: [ResolvedStoryListItem] = []
            resolvedItems.reserveCapacity(items.count)
            for item in items {
                switch resolveProductionListItem(
                    item,
                    resolver: resolver,
                    catalogUnavailability: catalogUnavailability
                ) {
                case let .success(resolved):
                    resolvedItems.append(resolved)
                case let .failure(reason):
                    return .failure(reason)
                }
            }
            return .success(.list(items: resolvedItems))
        }
    }

    static func resolveProductionListItem(
        _ item: FlavorTextListItem,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStoryListItem, StoryUnavailableReason> {
        switch resolveProductionEntry(
            item.entry,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(entry):
            var nested: [ResolvedStoryListItem] = []
            nested.reserveCapacity(item.nested.count)
            for child in item.nested {
                switch resolveProductionListItem(
                    child,
                    resolver: resolver,
                    catalogUnavailability: catalogUnavailability
                ) {
                case let .success(resolved):
                    nested.append(resolved)
                case let .failure(reason):
                    return .failure(reason)
                }
            }
            return .success(ResolvedStoryListItem(entry: entry, nested: nested))
        }
    }

    static func resolveKey(
        _ key: String,
        variables: JSONValue,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        if let chrome = chromeVocabulary[key] {
            return .success([.text(chrome)])
        }
        guard let resolver else { return .failure(catalogUnavailability) }
        return resolver.render(key: key, variables: variables)
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
        return vocabulary[String(rawValue.dropFirst())]
    }

    static func resolvedStaticEntry(
        _ entry: FlavorTextEntry, vocabulary: [String: String]
    ) -> ResolvedStoryEntry? {
        switch entry {
        case let .basic(text):
            return resolvedStaticLiteralOrKey(
                text, vocabulary: vocabulary
            ).map(ResolvedStoryEntry.text)
        case let .i18n(key, variables):
            guard let template = vocabulary[key],
                  let substituted = substituteVariables(template, variables: variables)
            else {
                return nil
            }
            return .text(substituted)
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
        }
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
