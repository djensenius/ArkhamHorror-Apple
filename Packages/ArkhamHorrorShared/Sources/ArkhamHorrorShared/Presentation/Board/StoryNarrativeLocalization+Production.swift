import Foundation

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
        catalogUnavailability: StoryUnavailableReason,
        fallsBackToServerKey: Bool = true
    ) -> Result<String?, StoryUnavailableReason> {
        guard let rawTitle else { return .success(nil) }
        guard rawTitle.hasPrefix("$") else { return .success(rawTitle) }
        let key = String(rawTitle.dropFirst())
        switch resolveKey(
            key,
            variables: .object([:]),
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ) {
        case let .failure(reason):
            guard fallsBackToServerKey,
                  let fallback = readableFallback(for: reason, key: key, variables: .object([:]))
            else {
                return .failure(reason)
            }
            return .success(fallback)
        case let .success(nodes):
            guard !nodes.contains(where: \.losesInstructionWhenFlattened) else {
                return .failure(.unsupportedEntry)
            }
            return .success(nodes.map(\.plainText).joined())
        }
    }

    static func resolveProductionChoiceLabel(
        _ wireLabel: String,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<String, StoryUnavailableReason> {
        guard wireLabel.hasPrefix("$") else { return .failure(.unsupportedEntry) }
        switch resolveProductionTitle(
            wireLabel,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            fallsBackToServerKey: false
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(label):
            guard let label else { return .failure(.unsupportedEntry) }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.unsupportedEntry) }
            return .success(trimmed)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func resolveProductionEntry(
        _ entry: FlavorTextEntry,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStoryEntry, StoryUnavailableReason> {
        switch entry {
        case let .basic(text):
            return resolveProductionBasicEntry(
                text,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .header(level, key):
            if let resolver {
                return resolver.render(key: key, variables: .object([:]))
                    .map { .heading(level: level, nodes: $0) }
                    .fallbackEntry(key: key, variables: .object([:])) { fallback in
                        .heading(level: level, nodes: [.text(fallback)])
                    }
            }
            return resolveKey(
                key,
                variables: .object([:]),
                resolver: nil,
                catalogUnavailability: catalogUnavailability
            ).map { .heading(level: level, nodes: $0) }
                .fallbackEntry(key: key, variables: .object([:])) { fallback in
                    .heading(level: level, nodes: [.text(fallback)])
                }
        case let .i18n(key, variables):
            return resolveProductionI18nEntry(
                key,
                variables: variables,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .modify(modifiers, entry):
            return resolveProductionEntry(
                entry,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map { .modified(modifiers: modifiers, entry: $0) }
        case let .composite(entries):
            return resolveProductionEntries(
                entries,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map { .composite(entries: $0) }
        case let .column(entries):
            return resolveProductionEntries(
                entries,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map { .columns(entries: $0) }
        case let .list(items):
            return resolveProductionListEntry(
                items,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .card(cardCode, imageModifiers):
            return .success(.cardReference(cardCode: cardCode, imageModifiers: imageModifiers))
        case let .tarot(arcana):
            return .success(.tarotReference(arcana: arcana))
        case let .chaosToken(face):
            return .success(.chaosTokenReference(face: face))
        case let .chaosTokenMorph(from, target):
            return .success(.chaosTokenMorph(from: from, target: target))
        case .split:
            return .success(.divider)
        }
    }

    static func resolveProductionBasicEntry(
        _ text: String,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStoryEntry, StoryUnavailableReason> {
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
            .fallbackEntry(key: key, variables: .object([:])) { .text($0) }
    }

    static func resolveProductionI18nEntry(
        _ key: String,
        variables: JSONValue,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStoryEntry, StoryUnavailableReason> {
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
            .fallbackEntry(key: key, variables: variables) { .text($0) }
    }

    static func resolveProductionEntries(
        _ entries: [FlavorTextEntry],
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<[ResolvedStoryEntry], StoryUnavailableReason> {
        var resolvedEntries: [ResolvedStoryEntry] = []
        resolvedEntries.reserveCapacity(entries.count)
        for entry in entries {
            switch resolveProductionEntry(
                entry,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ) {
            case let .success(resolved):
                resolvedEntries.append(resolved)
            case let .failure(reason):
                return .failure(reason)
            }
        }
        return .success(resolvedEntries)
    }

    static func resolveProductionListEntry(
        _ items: [FlavorTextListItem],
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStoryEntry, StoryUnavailableReason> {
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

    static func readableFallback(
        for reason: StoryUnavailableReason, key: String, variables: JSONValue
    ) -> String? {
        switch reason {
        case .catalog, .loading, .missingKey:
            readableServerFallback(key: key, variables: variables)
        case .imagePipelineUnavailable, .imageSourceLoading, .unsupportedEntry, .linkCycle,
             .missingVariable, .unsupportedVariableValue, .tooComplex:
            nil
        }
    }
}

private extension Result where Success == ResolvedStoryEntry, Failure == StoryUnavailableReason {
    func fallbackEntry(
        key: String,
        variables: JSONValue,
        makeEntry: (String) -> ResolvedStoryEntry
    ) -> Self {
        switch self {
        case .success:
            return self
        case let .failure(reason):
            guard let fallback = StoryNarrativeLocalization.readableFallback(
                for: reason, key: key, variables: variables
            ) else { return self }
            return .success(makeEntry(fallback))
        }
    }
}
