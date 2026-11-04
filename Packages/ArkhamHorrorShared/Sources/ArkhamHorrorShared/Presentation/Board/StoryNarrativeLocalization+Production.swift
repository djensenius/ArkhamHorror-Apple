// swiftlint:disable file_length
import Foundation

struct ProductionTitleResolution {
    let title: String?
    /// The title's inline nodes, set only when it carries a `[^N]` footnote reference.
    let titleNodes: [StoryNode]?
    let degradedReason: StoryUnavailableReason?

    init(
        title: String?,
        titleNodes: [StoryNode]? = nil,
        degradedReason: StoryUnavailableReason?
    ) {
        self.title = title
        self.titleNodes = titleNodes
        self.degradedReason = degradedReason
    }
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

struct ProductionChoiceLabelInvocation {
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
                titleNodes: titleResolution.titleNodes,
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
            // Story titles go through the web's `formatContent` too, so `[^N]` splits.
            return .success(footnotedTitle([.text(rawTitle)], degradedReason: nil))
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
            return .success(footnotedTitle(
                rendered.nodes, degradedReason: rendered.degradedReason
            ))
        }
    }

    /// A title whose `[^N]` references split out like story text. `title` stays the plain
    /// projection; `titleNodes` is set only when a footnote reference was split, with any
    /// catalog `<p>`/`<hN>` wrapper unwrapped so the inline title renderer accepts it.
    private static func footnotedTitle(
        _ nodes: [StoryNode], degradedReason: StoryUnavailableReason?
    ) -> ProductionTitleResolution {
        let footnoted = nodes.splittingFootnoteMarkers
        return ProductionTitleResolution(
            title: footnoted.map(\.plainText).joined(),
            titleNodes: footnoted.containsFootnoteMarker ? footnoted.unwrappingBlocks : nil,
            degradedReason: degradedReason
        )
    }

    static func resolveProductionChoiceLabel(
        _ wireLabel: String,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<String, StoryUnavailableReason> {
        resolveProductionChoiceLabelRich(
            wireLabel,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability
        ).map(\.title)
    }

    static func resolveProductionChoiceLabelRich(
        _ wireLabel: String,
        resolver: LocaleCatalogResolver?,
        catalogUnavailability: StoryUnavailableReason
    ) -> Result<BasicChoiceResolvedLabelText, StoryUnavailableReason> {
        guard wireLabel.hasPrefix("$") else { return .failure(.unsupportedEntry) }
        guard let invocation = parseProductionChoiceLabel(wireLabel) else {
            return .failure(.unsupportedVariableValue)
        }
        // Vue I18n resolves `$t(pluralKey)` without an explicit count through the singular
        // branch. Ask the resolver for that path; it only applies when `count`/`n` is absent,
        // so named variables still bind normally and unbound placeholders still fail closed.
        switch resolveKey(
            invocation.key,
            variables: invocation.variables,
            resolver: resolver,
            catalogUnavailability: catalogUnavailability,
            imageFallback: false,
            usesImplicitSingularPlural: true
        ) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(rendered):
            guard !rendered.nodes.contains(where: \.losesInstructionWhenFlattened) else {
                return .failure(.unsupportedEntry)
            }
            // A label with catalog icons keeps its nodes and is never re-parsed as a raw
            // label, so a text variable's raw `{icon}` or escape is formatted here first.
            let formatted = rendered.nodes.containsSemanticIcon
                ? rendered.nodes.formattingRawPlaceholderRuns
                : rendered.nodes
            let label = footnotedChoiceLabel(formatted)
            let trimmed = label.nodes.map(\.plainText).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.unsupportedEntry) }
            // Catalog `.icon` nodes for web icons keep their glyph in the choice title
            // instead of flattening to a word; `runeM` uses the glyph key `rune-M`.
            // Normalizing turns unknown icons into text nodes but does not merge them;
            // `trimmedTextEdges` then trims the edges and coalesces adjacent text. The inline
            // label renderer rejects `<p>`/`<hN>` wrappers, so they are unwrapped first.
            let nodes = label.hasMarker || label.nodes.containsSemanticIcon
                ? label.nodes.unwrappingBlocks.normalizingWebIconNames.trimmedTextEdges
                : nil
            let spoken = label.nodes.map(\.spokenText).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(BasicChoiceResolvedLabelText(
                title: trimmed, inlineNodes: nodes,
                accessibilityTitle: label.hasMarker ? spoken : nil
            ))
        }
    }

    /// Catalog choice labels go through the web's `formatContent`, so `[^N]` splits like
    /// story text. A text variable can still leave a raw `{icon}` or escape in the label;
    /// then the label stays unsplit so the legacy re-parse handles icons and footnotes in
    /// one pass (`productionVariableFootnoteIsParsed`). A label with catalog icon nodes
    /// keeps them as `inlineNodes` and is never re-parsed, so it splits regardless; its
    /// variable placeholders were already formatted (`formattingRawPlaceholderRuns`).
    private static func footnotedChoiceLabel(
        _ nodes: [StoryNode]
    ) -> (nodes: [StoryNode], hasMarker: Bool) {
        let footnoted = nodes.splittingFootnoteMarkers
        guard footnoted.containsFootnoteMarker,
              nodes.containsSemanticIcon || !StoryIconInlineParser.containsRawPlaceholder(
                  footnoted.map(\.plainText).joined()
              )
        else { return (nodes, false) }
        // The inline label renderer rejects `<p>`/`<hN>` wrappers, which would drop the marker.
        return (footnoted.unwrappingBlocks, true)
    }

    static func productionChoiceLabelCatalogKey(_ wireLabel: String) -> String? {
        parseProductionChoiceLabel(wireLabel)?.key
    }

    static func parseProductionChoiceLabel(
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
        case let .footnote(number, entry):
            resolveProductionEntry(
                entry,
                resolver: resolver,
                catalogUnavailability: catalogUnavailability
            ).map {
                ProductionEntryResolution(
                    entry: .footnote(number: number, entry: $0.entry),
                    degradedReason: $0.degradedReason
                )
            }
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
            return .success(ProductionEntryResolution(
                entry: footnotedTextEntry(text), degradedReason: nil
            ))
        }
        let key = String(text.dropFirst())
        if let chrome = chromeVocabulary[key] {
            return .success(ProductionEntryResolution(
                entry: footnotedTextEntry(chrome), degradedReason: nil
            ))
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
            return .success(ProductionEntryResolution(
                entry: footnotedTextEntry(text), degradedReason: nil
            ))
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

    /// Literal story text goes through the web's `formatContent` like catalog text, so
    /// `{icon}` and rune tokens, `_bold_`, `*italic*` and `[^N]` become nodes (icons as their
    /// catalog nodes) and `{asterisk}`/`{underscore}` unescape. Text that formats to plain
    /// text stays `.text`, so text without markup is unchanged.
    private static func footnotedTextEntry(_ text: String) -> ResolvedStoryEntry {
        let nodes = StoryIconInlineParser.runNodes(for: text, iconNode: \.catalogNode)
        // Empty input, or markup with nothing inside it (`**`), formats to no text at all.
        guard let first = nodes.first else { return .text("") }
        if nodes.count == 1, case let .text(plain) = first {
            return .text(plain)
        }
        return .nodes(nodes)
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
            // Story prose goes through the web's `formatContent`, which turns `[^N]` into a
            // footnote reference; the game log does not, so only the narrative layer splits.
            let footnoted = LocaleCatalogRenderedNodes(
                nodes: rendered.nodes.splittingFootnoteMarkers,
                degradedReason: rendered.degradedReason
            )
            return .success(ProductionEntryResolution(
                entry: makeResolved(footnoted),
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

private extension [StoryNode] {
    /// Whether any node, at any depth, is a split `[^N]` footnote reference.
    var containsFootnoteMarker: Bool {
        contains { node in
            switch node {
            case .footnoteMarker:
                true
            case let .group(children), let .paragraph(children), let .heading(_, children),
                 let .emphasis(_, children), let .cardReference(_, children):
                children.containsFootnoteMarker
            case let .list(_, items):
                items.contains { $0.containsFootnoteMarker }
            case let .table(head, body):
                (head + body).contains { row in
                    row.cells.contains { $0.children.containsFootnoteMarker }
                }
            case .text, .lineBreak, .rule, .image, .icon, .semanticIcon:
                false
            }
        }
    }

    var containsSemanticIcon: Bool {
        contains { node in
            switch node {
            case .semanticIcon:
                true
            case let .icon(name):
                WebIconPlaceholder(placeholderName: name) != nil
            case let .group(children), let .paragraph(children), let .heading(_, children),
                 let .emphasis(_, children), let .cardReference(_, children):
                children.containsSemanticIcon
            case let .list(_, items):
                items.contains { $0.containsSemanticIcon }
            case .text, .lineBreak, .rule, .image, .table, .footnoteMarker:
                false
            }
        }
    }

    var normalizingWebIconNames: [StoryNode] {
        map { node in
            switch node {
            case let .icon(name):
                // A name the web does not treat as an icon stays the word it flattened to.
                WebIconPlaceholder(placeholderName: name).map { .icon($0.glyphKey) }
                    ?? .text(StoryNode.spokenIconLabel(name))
            case let .group(children):
                .group(children.normalizingWebIconNames)
            case let .paragraph(children):
                .paragraph(children.normalizingWebIconNames)
            case let .heading(level, children):
                .heading(level: level, children: children.normalizingWebIconNames)
            case let .emphasis(style, children):
                .emphasis(style, children.normalizingWebIconNames)
            case let .cardReference(code, children):
                .cardReference(code: code, children: children.normalizingWebIconNames)
            case .text, .lineBreak, .rule, .image, .table, .list, .semanticIcon, .footnoteMarker:
                node
            }
        }
    }

    /// Every text node with its `[^N]` footnote references split out, at any depth.
    ///
    /// `LocaleCatalogResolver` emits an interpolated variable value as its own plain `.text`
    /// sibling (`Note[^{number}].` arrives as "Note[^", "5", "]."), and like the web, which
    /// applies `formatContent` after interpolation, the reference must still split. So each
    /// level scans its consecutive `.text` siblings as one run. `.text` carries no styling
    /// or variable marker, and every other node (emphasis, icons, card references) ends a
    /// run. A run without a footnote keeps its original nodes.
    var splittingFootnoteMarkers: [StoryNode] {
        var result: [StoryNode] = []
        var run: [String] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            let split = StoryNode.splittingFootnoteMarkers(in: run.joined())
            let hasMarker = split.contains { node in
                guard case .footnoteMarker = node else { return false }
                return true
            }
            result += hasMarker ? split : run.map(StoryNode.text)
            run = []
        }
        for node in self {
            if case let .text(text) = node {
                run.append(text)
            } else {
                flushRun()
                result.append(node.splittingNestedFootnoteMarkers)
            }
        }
        flushRun()
        return result
    }
}

private extension StoryNode {
    /// `self` with footnote references split inside its children. Text is split by the
    /// enclosing sibling run, so a bare `.text` is returned unchanged.
    var splittingNestedFootnoteMarkers: StoryNode {
        switch self {
        case let .group(children):
            .group(children.splittingFootnoteMarkers)
        case let .paragraph(children):
            .paragraph(children.splittingFootnoteMarkers)
        case let .heading(level, children):
            .heading(level: level, children: children.splittingFootnoteMarkers)
        case let .emphasis(style, children):
            .emphasis(style, children.splittingFootnoteMarkers)
        case let .cardReference(code, children):
            .cardReference(code: code, children: children.splittingFootnoteMarkers)
        case let .list(ordered, items):
            .list(ordered: ordered, items: items.map(\.splittingFootnoteMarkers))
        case let .table(head, body):
            .table(
                head: head.map(\.splittingFootnoteMarkers),
                body: body.map(\.splittingFootnoteMarkers)
            )
        case .text, .lineBreak, .rule, .image, .icon, .semanticIcon, .footnoteMarker:
            self
        }
    }
}

private extension [StoryNode] {
    /// Each maximal run of sibling `.text` nodes that holds a raw `{icon}`, rune token or
    /// `{asterisk}`/`{underscore}` escape (from a text variable; catalog icons are already
    /// nodes), parsed like the web's `formatContent` (icons, `_bold_`, `*italic*`, `[^N]`,
    /// escapes), at any inline depth. Every other run, including one whose only raw
    /// placeholder is a `[^N]` reference, is unchanged, so literal catalog `*x*` stays text
    /// and `footnotedChoiceLabel` splits markers as before.
    var formattingRawPlaceholderRuns: [StoryNode] {
        var result: [StoryNode] = []
        var run: [String] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            let text = run.joined()
            let hasIconOrEscape = StoryNode.splittingFootnoteMarkers(in: text).contains { node in
                guard case let .text(piece) = node else { return false }
                return StoryIconInlineParser.containsRawPlaceholder(piece)
            }
            result += hasIconOrEscape
                ? StoryIconInlineParser.runNodes(for: text, iconNode: \.catalogNode)
                : run.map(StoryNode.text)
            run = []
        }
        for node in self {
            if case let .text(text) = node {
                run.append(text)
                continue
            }
            flushRun()
            result.append(node.formattingNestedRawPlaceholderRuns)
        }
        flushRun()
        return result
    }

    /// Paragraph and heading wrappers spliced into their parent, at any inline depth, so a
    /// one-line title or choice label renders inline. Their plain text is unchanged, since
    /// `plainText` joins sibling blocks without a separator too.
    var unwrappingBlocks: [StoryNode] {
        flatMap { node -> [StoryNode] in
            switch node {
            case let .paragraph(children), let .heading(_, children):
                children.unwrappingBlocks
            case let .group(children):
                [.group(children.unwrappingBlocks)]
            case let .emphasis(style, children):
                [.emphasis(style, children.unwrappingBlocks)]
            case let .cardReference(code, children):
                [.cardReference(code: code, children: children.unwrappingBlocks)]
            case .text, .lineBreak, .rule, .image, .icon, .semanticIcon, .footnoteMarker,
                 .list, .table:
                [node]
            }
        }
    }

    var trimmedTextEdges: [StoryNode] {
        var nodes = self
        while let first = nodes.first, case let .text(text) = first {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                nodes.removeFirst()
            } else {
                nodes[0] = .text(text.trimmingPrefixWhitespace)
                break
            }
        }
        while let last = nodes.last, case let .text(text) = last {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                nodes.removeLast()
            } else {
                nodes[nodes.count - 1] = .text(text.trimmingSuffixWhitespace)
                break
            }
        }
        return nodes.coalescingAdjacentText
    }

    private var coalescingAdjacentText: [StoryNode] {
        reduce(into: []) { result, node in
            switch (node, result.last) {
            case let (.text(text), .text(existing)?):
                result[result.count - 1] = .text(existing + text)
            default:
                result.append(node)
            }
        }
    }
}

private extension StoryNode {
    /// `self` with raw-placeholder text runs formatted inside its inline children.
    var formattingNestedRawPlaceholderRuns: StoryNode {
        switch self {
        case let .group(children):
            .group(children.formattingRawPlaceholderRuns)
        case let .paragraph(children):
            .paragraph(children.formattingRawPlaceholderRuns)
        case let .heading(level, children):
            .heading(level: level, children: children.formattingRawPlaceholderRuns)
        case let .emphasis(style, children):
            .emphasis(style, children.formattingRawPlaceholderRuns)
        case let .cardReference(code, children):
            .cardReference(code: code, children: children.formattingRawPlaceholderRuns)
        case .text, .lineBreak, .rule, .image, .icon, .semanticIcon, .footnoteMarker,
             .list, .table:
            self
        }
    }
}

private extension WebIconPlaceholder {
    /// The node a catalog `icon` variable resolves to before `normalizingWebIconNames`:
    /// a rune keeps its placeholder name (`runeM`), every other icon its parsed node.
    var catalogNode: StoryNode {
        if case let .rune(letter) = self {
            return .icon("rune\(letter)")
        }
        return node
    }
}

private extension StoryTableRow {
    var splittingFootnoteMarkers: StoryTableRow {
        StoryTableRow(cells: cells.map { cell in
            StoryTableCell(
                isHeader: cell.isHeader, children: cell.children.splittingFootnoteMarkers
            )
        })
    }
}

private extension String {
    var trimmingPrefixWhitespace: String {
        String(drop(while: { $0.isWhitespace }))
    }

    var trimmingSuffixWhitespace: String {
        guard let lastContentIndex = lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[...lastContentIndex])
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
