// swiftlint:disable file_length
import Foundation

struct ProductionTitleResolution {
    let title: String?
    let degradedReason: StoryUnavailableReason?
}

struct ProductionEntryResolution {
    let entry: ResolvedStoryEntry
    let degradedReason: StoryUnavailableReason?
}

struct ProductionEntriesResolution {
    let entries: [ResolvedStoryEntry]
    let degradedReason: StoryUnavailableReason?
}

struct ProductionListItemResolution {
    let item: ResolvedStoryListItem
    let degradedReason: StoryUnavailableReason?
}

private struct ProductionChoiceLabelInvocation {
    let key: String
    let variables: JSONValue
}

// MARK: - Production catalog resolution

extension StoryNarrativeLocalization {
    static func resolveProductionStory(
        _ flavorText: FlavorText,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ResolvedStory, StoryUnavailableReason> {
        switch resolveProductionStoryTitle(
            flavorText.title,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(titleResolution):
            var body: [ResolvedStoryEntry] = []
            var degradedReason = titleResolution.degradedReason
            body.reserveCapacity(flavorText.body.count)
            for entry in flavorText.body {
                switch resolveProductionEntry(
                    entry,
                    resolver: resolver,
                    catalogUnavailability: catalogUnavailability
                ) {
                case let .success(resolved):
                    body.append(resolved.entry)
                    degradedReason = degradedReason.combined(with: resolved.degradedReason)
                case let .failure(reason):
                    return .failure(reason)
                }
            }
            return .success(ResolvedStory(
                title: titleResolution.title,
                body: body,
                degradedReason: degradedReason
            ))
        }
    }

    static func resolveProductionTitle(
        _ rawTitle: String?,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason,
        fallsBackToServerKey: Bool = true
    ) -> Result<String?, StoryUnavailableReason> {
        resolveProductionStoryTitle(
            rawTitle,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            fallsBackToServerKey: fallsBackToServerKey
        ).map(\.title)
    }

    static func resolveProductionStoryTitle(
        _ rawTitle: String?,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason,
        fallsBackToServerKey: Bool = true
    ) -> Result<ProductionTitleResolution, StoryUnavailableReason> {
        guard let rawTitle else {
            return .success(ProductionTitleResolution(title: nil, degradedReason: nil))
        }
        guard rawTitle.hasPrefix("$") else {
            return .success(ProductionTitleResolution(title: rawTitle, degradedReason: nil))
        }
        let key = String(rawTitle.dropFirst())
        switch resolveKey(
            key,
            variables: .object([:]),
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            imageFallback: fallsBackToServerKey
        ) {
        case let .failure(reason):
            guard fallsBackToServerKey,
                  let fallback = readableFallback(
                      for: reason, key: key, variables: .object([:]), resolver: resolver
                  )
            else {
                return .failure(reason)
            }
            return .success(ProductionTitleResolution(
                title: fallback,
                degradedReason: degradedReason(for: reason, resolver: resolver)
            ))
        case let .success(rendered):
            guard !rendered.nodes.contains(where: \.losesInstructionWhenFlattened) else {
                return .failure(.unsupportedEntry)
            }
            return .success(ProductionTitleResolution(
                title: rendered.nodes.map(\.plainText).joined(),
                degradedReason: rendered.degradedReason
            ))
        }
    }

    static func resolveProductionChoiceLabel(
        _ wireLabel: String,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<String, StoryUnavailableReason> {
        guard wireLabel.hasPrefix("$") else { return .failure(.unsupportedEntry) }
        guard let invocation = parseProductionChoiceLabel(wireLabel) else {
            return .failure(.unsupportedVariableValue)
        }
        for key in productionChoiceLabelCandidateKeys(invocation.key) {
            // Vue I18n resolves `$t(pluralKey)` without an explicit count through the singular
            // branch. Ask the resolver for that path; it only applies when `count`/`n` is absent,
            // so named variables still bind normally and unbound placeholders still fail closed.
            switch resolveKey(
                key,
                variables: invocation.variables,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability,
                imageFallback: false,
                usesImplicitSingularPlural: true
            ) {
            case .failure(.missingKey) where key == invocation.key:
                continue
            case let .failure(reason):
                return .failure(reason)
            case let .success(rendered):
                guard !rendered.nodes.contains(where: \.losesInstructionWhenFlattened) else {
                    return .failure(.unsupportedEntry)
                }
                let trimmed = rendered.nodes.map(\.plainText).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .failure(.unsupportedEntry) }
                return .success(trimmed)
            }
        }
        return .failure(.missingKey)
    }

    private static func productionChoiceLabelCandidateKeys(_ key: String) -> [String] {
        key.contains(".") ? [key] : [key, "choice.\(key)"]
    }

    private static func parseProductionChoiceLabel(
        _ wireLabel: String
    ) -> ProductionChoiceLabelInvocation? {
        var input = wireLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("$") else { return nil }
        input = String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let parts = splitChoiceLabelKeyAndParameters(input)
        guard LocaleCatalogGrammar.isMessageKey(parts.key) else { return nil }
        guard let variables = parseChoiceLabelVariables(parts.parameters) else { return nil }
        return ProductionChoiceLabelInvocation(key: parts.key, variables: .object(variables))
    }

    private static func splitChoiceLabelKeyAndParameters(
        _ input: String
    ) -> (key: String, parameters: String) {
        guard let spaceIndex = input.firstIndex(of: " ") else { return (input, "") }
        let key = String(input[..<spaceIndex])
        let parameters = input[input.index(after: spaceIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, parameters)
    }

    private static func parseChoiceLabelVariables(
        _ parameters: String
    ) -> [String: JSONValue]? {
        guard !parameters.isEmpty else { return [:] }
        var variables: [String: JSONValue] = [:]
        guard let tokens = tokenizeChoiceLabelParameters(parameters) else { return nil }
        for token in tokens {
            guard let separator = token.firstIndex(of: "=") else { return nil }
            let name = String(token[..<separator])
            let encodedValue = token[token.index(after: separator)...]
            guard LocaleCatalogGrammar.isVariableName(name),
                  variables[name] == nil
            else { return nil }
            guard let value = parseChoiceLabelVariableValue(encodedValue) else { return nil }
            variables[name] = value
        }
        return variables
    }

    private static func tokenizeChoiceLabelParameters(_ parameters: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in parameters {
            if let activeQuote = quote {
                if character != "\\" {
                    current.append(character)
                }
                if character == activeQuote, !escaped {
                    quote = nil
                }
                if character == "\\", !escaped {
                    escaped = true
                } else {
                    escaped = false
                }
            } else if character == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
                if character == "\"" || character == "'" {
                    quote = character
                }
            }
        }
        guard quote == nil else { return nil }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func parseChoiceLabelVariableValue(
        _ encodedValue: some StringProtocol
    ) -> JSONValue? {
        if encodedValue.hasPrefix("i:") {
            let raw = String(encodedValue.dropFirst(2))
            guard let number = parseChoiceLabelInteger(raw) else { return nil }
            return .number(number)
        }
        if encodedValue.hasPrefix("s:") {
            let raw = String(encodedValue.dropFirst(2))
            guard raw.count >= 2,
                  let first = raw.first,
                  first == "\"" || first == "'",
                  raw.last == first
            else { return nil }
            return .string(String(raw.dropFirst().dropLast()))
        }
        return nil
    }

    private static func parseChoiceLabelInteger(_ raw: String) -> JSONNumber? {
        guard let parsed = try? JSONNumber(exactDecimalLiteral: raw),
              let magnitude = parsed.wholeNumberMagnitude
        else { return nil }
        let sign: JSONNumber.Sign = parsed.sign == .minus && magnitude != "0" ? .minus : .plus
        return try? JSONNumber(sign: sign, coefficient: magnitude, exponent: .zero)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func resolveProductionEntry(
        _ entry: FlavorTextEntry,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ProductionEntryResolution, StoryUnavailableReason> {
        switch entry {
        case let .basic(text):
            resolveProductionBasicEntry(
                text,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .header(level, key):
            resolveProductionCatalogEntry(
                key,
                variables: .object([:]),
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ) { fallback in
                .heading(level: level, nodes: [.text(fallback)])
            } makeResolved: { rendered in
                .heading(level: level, nodes: rendered.nodes)
            }
        case let .i18n(key, variables):
            resolveProductionI18nEntry(
                key,
                variables: variables,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .modify(modifiers, entry):
            resolveProductionEntry(
                entry,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map {
                ProductionEntryResolution(
                    entry: .modified(modifiers: modifiers, entry: $0.entry),
                    degradedReason: $0.degradedReason
                )
            }
        case let .composite(entries):
            resolveProductionEntries(
                entries,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map {
                ProductionEntryResolution(
                    entry: .composite(entries: $0.entries),
                    degradedReason: $0.degradedReason
                )
            }
        case let .column(entries):
            resolveProductionEntries(
                entries,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map {
                ProductionEntryResolution(
                    entry: .columns(entries: $0.entries),
                    degradedReason: $0.degradedReason
                )
            }
        case let .list(items):
            resolveProductionListEntry(
                items,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            )
        case let .card(cardCode, imageModifiers):
            .success(ProductionEntryResolution(
                entry: .cardReference(cardCode: cardCode, imageModifiers: imageModifiers),
                degradedReason: nil
            ))
        case let .tarot(arcana):
            .success(ProductionEntryResolution(
                entry: .tarotReference(arcana: arcana), degradedReason: nil
            ))
        case let .chaosToken(face):
            .success(ProductionEntryResolution(
                entry: .chaosTokenReference(face: face), degradedReason: nil
            ))
        case let .chaosTokenMorph(from, target):
            .success(ProductionEntryResolution(
                entry: .chaosTokenMorph(from: from, target: target), degradedReason: nil
            ))
        case .split:
            .success(ProductionEntryResolution(entry: .divider, degradedReason: nil))
        case let .unknown(tag, text):
            .success(ProductionEntryResolution(
                entry: .text(readableUnknownEntry(tag: tag, text: text)),
                degradedReason: nil
            ))
        }
    }

    static func resolveProductionBasicEntry(
        _ text: String,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ProductionEntryResolution, StoryUnavailableReason> {
        guard text.hasPrefix("$") else {
            return .success(ProductionEntryResolution(entry: .text(text), degradedReason: nil))
        }
        let key = String(text.dropFirst())
        if let chrome = chromeVocabulary[key] {
            return .success(ProductionEntryResolution(entry: .text(chrome), degradedReason: nil))
        }
        return resolveProductionCatalogEntry(
            key,
            variables: .object([:]),
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            makeFallback: { .text($0) },
            makeResolved: { .nodes($0.nodes) }
        )
    }

    static func resolveProductionI18nEntry(
        _ key: String,
        variables: JSONValue,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ProductionEntryResolution, StoryUnavailableReason> {
        if let chrome = chromeVocabulary[key] {
            guard let text = substituteVariables(chrome, variables: variables) else {
                return .failure(.missingVariable)
            }
            return .success(ProductionEntryResolution(entry: .text(text), degradedReason: nil))
        }
        return resolveProductionCatalogEntry(
            key,
            variables: variables,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            makeFallback: { .text($0) },
            makeResolved: { .nodes($0.nodes) }
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func resolveProductionCatalogEntry(
        _ key: String,
        variables: JSONValue,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason,
        makeFallback: (String) -> ResolvedStoryEntry,
        makeResolved: (LocaleCatalogRenderedNodes) -> ResolvedStoryEntry
    ) -> Result<ProductionEntryResolution, StoryUnavailableReason> {
        switch resolveKey(
            key,
            variables: variables,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            imageFallback: true
        ) {
        case let .success(rendered):
            return .success(ProductionEntryResolution(
                entry: makeResolved(rendered),
                degradedReason: rendered.degradedReason
            ))
        case let .failure(reason):
            guard let fallback = readableFallback(
                for: reason, key: key, variables: variables, resolver: resolver
            ) else {
                return .failure(reason)
            }
            return .success(ProductionEntryResolution(
                entry: makeFallback(fallback),
                degradedReason: degradedReason(for: reason, resolver: resolver)
            ))
        }
    }

    static func resolveProductionEntries(
        _ entries: [FlavorTextEntry],
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ProductionEntriesResolution, StoryUnavailableReason> {
        var resolvedEntries: [ResolvedStoryEntry] = []
        var degradedReason: StoryUnavailableReason?
        resolvedEntries.reserveCapacity(entries.count)
        for entry in entries {
            switch resolveProductionEntry(
                entry,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ) {
            case let .success(resolved):
                resolvedEntries.append(resolved.entry)
                degradedReason = degradedReason.combined(with: resolved.degradedReason)
            case let .failure(reason):
                return .failure(reason)
            }
        }
        return .success(ProductionEntriesResolution(
            entries: resolvedEntries,
            degradedReason: degradedReason
        ))
    }

    static func resolveProductionListEntry(
        _ items: [FlavorTextListItem],
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ProductionEntryResolution, StoryUnavailableReason> {
        var resolvedItems: [ResolvedStoryListItem] = []
        var degradedReason: StoryUnavailableReason?
        resolvedItems.reserveCapacity(items.count)
        for item in items {
            switch resolveProductionListItem(
                item,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ) {
            case let .success(resolved):
                resolvedItems.append(resolved.item)
                degradedReason = degradedReason.combined(with: resolved.degradedReason)
            case let .failure(reason):
                return .failure(reason)
            }
        }
        return .success(ProductionEntryResolution(
            entry: .list(items: resolvedItems),
            degradedReason: degradedReason
        ))
    }

    static func resolveProductionListItem(
        _ item: FlavorTextListItem,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<ProductionListItemResolution, StoryUnavailableReason> {
        switch resolveProductionEntry(
            item.entry,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(entry):
            var nested: [ResolvedStoryListItem] = []
            var degradedReason = entry.degradedReason
            nested.reserveCapacity(item.nested.count)
            for child in item.nested {
                switch resolveProductionListItem(
                    child,
                    resolver: resolver,
                    catalogUnavailability: catalogUnavailability
                ) {
                case let .success(resolved):
                    nested.append(resolved.item)
                    degradedReason = degradedReason.combined(with: resolved.degradedReason)
                case let .failure(reason):
                    return .failure(reason)
                }
            }
            return .success(ProductionListItemResolution(
                item: ResolvedStoryListItem(entry: entry.entry, nested: nested),
                degradedReason: degradedReason
            ))
        }
    }

    static func resolveKey(
        _ key: String,
        variables: JSONValue,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason,
        imageFallback: Bool = true,
        usesImplicitSingularPlural: Bool = false
    ) -> Result<LocaleCatalogRenderedNodes, StoryUnavailableReason> {
        guard let resolver else {
            if let chrome = chromeVocabulary[key] {
                return .success(LocaleCatalogRenderedNodes(
                    nodes: [.text(chrome)], degradedReason: nil
                ))
            }
            return .failure(catalogUnavailability)
        }
        let rendered = if imageFallback {
            resolver.renderAllowingImageFallback(key: key, variables: variables)
        } else if usesImplicitSingularPlural {
            resolver.renderUsingImplicitSingularPlural(key: key, variables: variables).map {
                LocaleCatalogRenderedNodes(nodes: $0, degradedReason: nil)
            }
        } else {
            resolver.render(key: key, variables: variables).map {
                LocaleCatalogRenderedNodes(nodes: $0, degradedReason: nil)
            }
        }
        if case .failure(.missingKey) = rendered, let chrome = chromeVocabulary[key] {
            return .success(LocaleCatalogRenderedNodes(nodes: [.text(chrome)], degradedReason: nil))
        }
        return rendered
    }

    static func readableFallback(
        for reason: StoryUnavailableReason,
        key: String,
        variables: JSONValue,
        resolver: LocaleCatalogResolver?
    ) -> String? {
        switch reason {
        case .missingKey, .unsupportedEntry:
            readableServerFallback(key: key, variables: variables)
        case .catalog where resolver == nil:
            readableServerFallback(key: key, variables: variables)
        case .loading where resolver == nil:
            nil
        case .imagePipelineUnavailable, .imageSourceLoading, .linkCycle,
             .missingVariable, .unsupportedVariableValue, .tooComplex, .catalog, .loading:
            nil
        }
    }

    static func degradedReason(
        for reason: StoryUnavailableReason,
        resolver: LocaleCatalogResolver?
    ) -> StoryUnavailableReason? {
        switch reason {
        case .missingKey:
            nil
        case .unsupportedEntry:
            reason
        case let .catalog(failure) where resolver == nil:
            failure.isRetryable ? reason : nil
        case .catalog, .loading, .imagePipelineUnavailable, .imageSourceLoading,
             .linkCycle, .missingVariable, .unsupportedVariableValue, .tooComplex:
            nil
        }
    }
}

private extension StoryUnavailableReason {
    var isStoryRetryable: Bool {
        switch self {
        case let .catalog(failure):
            failure.isRetryable
        case .imagePipelineUnavailable:
            true
        case .loading, .imageSourceLoading, .missingKey, .unsupportedEntry, .linkCycle,
             .missingVariable, .unsupportedVariableValue, .tooComplex:
            false
        }
    }
}

private extension StoryUnavailableReason? {
    func combined(with other: StoryUnavailableReason?) -> StoryUnavailableReason? {
        guard let current = self else { return other }
        guard !current.isStoryRetryable, let other, other.isStoryRetryable else {
            return current
        }
        return other
    }
}
