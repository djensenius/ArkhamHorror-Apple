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
            return resolveProductionBasicEntry(
                text,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .header(level, key):
            guard let resolver else { return .failure(catalogUnavailability) }
            return resolver.render(key: key, variables: .object([:]))
                .map { .heading(level: level, nodes: $0) }
        case let .i18n(key, variables):
            return resolveProductionI18nEntry(
                key,
                variables: variables,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .list(items):
            return resolveProductionListEntry(
                items,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
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
}
