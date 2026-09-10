import Foundation

private struct LocaleCatalogLocatedEntry {
    let locale: String
    let entry: LocaleCatalogEntry
}

private struct LocaleCatalogResolutionKey: Hashable {
    let locale: String
    let key: String
}

/// Resolves an entry against one immutable snapshot without crossing locale contexts.
struct LocaleCatalogResolver: Sendable { // swiftlint:disable:this type_body_length
    let snapshot: LocaleCatalogSnapshot
    let assetSource: AssetSourceNamespace?
    let assetUnavailability: StoryUnavailableReason

    init(
        snapshot: LocaleCatalogSnapshot,
        assetSource: AssetSourceNamespace? = nil,
        assetUnavailability: StoryUnavailableReason = .unsupportedEntry
    ) {
        self.snapshot = snapshot
        self.assetSource = assetSource
        self.assetUnavailability = assetUnavailability
    }

    func render(
        key: String, variables: JSONValue
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        var budget = LocaleCatalogLimits.maxRenderedNodes
        return render(
            key: key,
            startingLocale: snapshot.identity.locale,
            variables: variables,
            visiting: [],
            budget: &budget
        )
    }

    private func render(
        key: String,
        startingLocale: String,
        variables: JSONValue,
        visiting: Set<LocaleCatalogResolutionKey>,
        budget: inout Int
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        guard visiting.count < LocaleCatalogLimits.maxLinkDepth else {
            return .failure(.tooComplex)
        }
        guard let located = lookup(key, startingAt: startingLocale) else {
            return .failure(.missingKey)
        }
        let resolutionKey = LocaleCatalogResolutionKey(locale: located.locale, key: key)
        guard !visiting.contains(resolutionKey) else {
            return .failure(.linkCycle)
        }
        let nodes: [LocaleCatalogNode]
        switch located.entry {
        case let .message(messageNodes, _):
            nodes = messageNodes
        case let .plural(cases, _):
            switch LocaleCatalogPluralRules.select(
                variables: variables, caseCount: cases.count, locale: located.locale
            ) {
            case let .success(index):
                guard cases.indices.contains(index) else {
                    return .failure(.unsupportedEntry)
                }
                nodes = cases[index]
            case let .failure(reason):
                return .failure(reason)
            }
        case .unsupported:
            return .failure(.unsupportedEntry)
        }
        var nextVisiting = visiting
        nextVisiting.insert(resolutionKey)
        return render(
            nodes: nodes,
            locale: located.locale,
            variables: variables,
            visiting: nextVisiting,
            budget: &budget
        )
    }

    /// Looks up `key` from the locale that supplied its parent entry, not from the snapshot's
    /// selected locale. A fallback English parent therefore resolves `@:term` from English
    /// first, preserving one language through the entire linked subtree.
    private func lookup(_ key: String, startingAt locale: String) -> LocaleCatalogLocatedEntry? {
        for candidate in snapshot.manifest.localeChain(from: locale) {
            if let entry = snapshot.entry(for: key, locale: candidate) {
                return LocaleCatalogLocatedEntry(locale: candidate, entry: entry)
            }
        }
        return nil
    }

    private func render(
        nodes: [LocaleCatalogNode],
        locale: String,
        variables: JSONValue,
        visiting: Set<LocaleCatalogResolutionKey>,
        budget: inout Int
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        var rendered: [StoryNode] = []
        rendered.reserveCapacity(nodes.count)
        for node in nodes {
            guard budget > 0 else { return .failure(.tooComplex) }
            budget -= 1
            switch renderNode(
                node,
                locale: locale,
                variables: variables,
                visiting: visiting,
                budget: &budget
            ) {
            case let .success(children):
                rendered.append(contentsOf: children)
            case let .failure(reason):
                return .failure(reason)
            }
        }
        return .success(rendered)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func renderNode(
        _ node: LocaleCatalogNode,
        locale: String,
        variables: JSONValue,
        visiting: Set<LocaleCatalogResolutionKey>,
        budget: inout Int
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        switch node {
        case let .text(text):
            .success([.text(text)])
        case let .variable(name, _, isIcon):
            renderVariable(name: name, isIcon: isIcon, variables: variables)
        case let .linked(target, modifier):
            renderLink(
                target: target,
                modifier: modifier,
                locale: locale,
                variables: variables,
                visiting: visiting,
                budget: &budget
            )
        case .lineBreak:
            .success([.lineBreak])
        case .rule:
            .success([.rule])
        case let .block(isParagraph, children):
            mapChildren(children, locale, variables, visiting, &budget) {
                isParagraph ? .paragraph($0) : .group($0)
            }
        case let .heading(level, children):
            mapChildren(children, locale, variables, visiting, &budget) {
                .heading(level: level, children: $0)
            }
        case let .emphasis(style, children):
            mapChildren(children, locale, variables, visiting, &budget) {
                .emphasis(style, $0)
            }
        case let .list(ordered, items):
            renderList(
                ordered: ordered,
                items: items,
                locale: locale,
                variables: variables,
                visiting: visiting,
                budget: &budget
            )
        case let .image(role, assetPath, alt):
            renderImage(role: role, assetPath: assetPath, alt: alt)
        case let .cardReference(code, children):
            mapChildren(children, locale, variables, visiting, &budget) {
                .cardReference(code: code, children: $0)
            }
        case let .table(head, body):
            renderTable(
                head: head,
                body: body,
                locale: locale,
                variables: variables,
                visiting: visiting,
                budget: &budget
            )
        }
    }

    private func renderImage(
        role: LocaleCatalogAssetRole, assetPath: String, alt: String?
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        guard CatalogImageAsset(role: role, assetPath: assetPath) != nil else {
            return .failure(.unsupportedEntry)
        }
        let reference = StoryAssetReference(
            role: role, assetPath: assetPath, alt: alt, source: assetSource
        )
        guard reference.assetKey != nil else { return .failure(assetUnavailability) }
        return .success([.image(reference)])
    }

    // swiftlint:disable:next function_parameter_count
    private func mapChildren(
        _ children: [LocaleCatalogNode],
        _ locale: String,
        _ variables: JSONValue,
        _ visiting: Set<LocaleCatalogResolutionKey>,
        _ budget: inout Int,
        _ transform: ([StoryNode]) -> StoryNode
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        render(
            nodes: children,
            locale: locale,
            variables: variables,
            visiting: visiting,
            budget: &budget
        ).map { [transform($0)] }
    }

    // swiftlint:disable:next function_parameter_count
    private func renderList(
        ordered: Bool,
        items: [[LocaleCatalogNode]],
        locale: String,
        variables: JSONValue,
        visiting: Set<LocaleCatalogResolutionKey>,
        budget: inout Int
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        var rendered: [[StoryNode]] = []
        rendered.reserveCapacity(items.count)
        for item in items {
            switch render(
                nodes: item,
                locale: locale,
                variables: variables,
                visiting: visiting,
                budget: &budget
            ) {
            case let .success(children):
                rendered.append(children)
            case let .failure(reason):
                return .failure(reason)
            }
        }
        return .success([.list(ordered: ordered, items: rendered)])
    }

    // swiftlint:disable:next function_parameter_count
    private func renderTable(
        head: [LocaleCatalogTableRow],
        body: [LocaleCatalogTableRow],
        locale: String,
        variables: JSONValue,
        visiting: Set<LocaleCatalogResolutionKey>,
        budget: inout Int
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        switch renderRows(head, locale, variables, visiting, &budget) {
        case let .failure(reason):
            .failure(reason)
        case let .success(renderedHead):
            switch renderRows(body, locale, variables, visiting, &budget) {
            case let .failure(reason):
                .failure(reason)
            case let .success(renderedBody):
                .success([.table(head: renderedHead, body: renderedBody)])
            }
        }
    }

    private func renderRows(
        _ rows: [LocaleCatalogTableRow],
        _ locale: String,
        _ variables: JSONValue,
        _ visiting: Set<LocaleCatalogResolutionKey>,
        _ budget: inout Int
    ) -> Result<[StoryTableRow], StoryUnavailableReason> {
        var rendered: [StoryTableRow] = []
        rendered.reserveCapacity(rows.count)
        for row in rows {
            var cells: [StoryTableCell] = []
            cells.reserveCapacity(row.cells.count)
            for cell in row.cells {
                switch render(
                    nodes: cell.children,
                    locale: locale,
                    variables: variables,
                    visiting: visiting,
                    budget: &budget
                ) {
                case let .success(children):
                    cells.append(StoryTableCell(isHeader: cell.isHeader, children: children))
                case let .failure(reason):
                    return .failure(reason)
                }
            }
            rendered.append(StoryTableRow(cells: cells))
        }
        return .success(rendered)
    }

    private func renderVariable(
        name: String,
        isIcon: Bool,
        variables: JSONValue
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        guard case let .object(object) = variables else {
            return isIcon ? .success([.icon(name)]) : .failure(.missingVariable)
        }
        guard let value = object[name] else {
            return isIcon ? .success([.icon(name)]) : .failure(.missingVariable)
        }
        guard let text = Self.losslessText(value) else {
            return .failure(.unsupportedVariableValue)
        }
        return .success([.text(text)])
    }

    // swiftlint:disable:next function_parameter_count
    private func renderLink(
        target: LocaleCatalogLinkTarget,
        modifier: LocaleCatalogLinkModifier?,
        locale: String,
        variables: JSONValue,
        visiting: Set<LocaleCatalogResolutionKey>,
        budget: inout Int
    ) -> Result<[StoryNode], StoryUnavailableReason> {
        let key: String
        switch target {
        case let .staticKey(staticKey):
            key = staticKey
        case let .variable(name, _):
            guard case let .object(object) = variables, let value = object[name] else {
                return .failure(.missingVariable)
            }
            guard case let .string(text) = value, LocaleCatalogGrammar.isMessageKey(text) else {
                return .failure(.unsupportedVariableValue)
            }
            key = text
        }
        let rendered = render(
            key: key,
            startingLocale: locale,
            variables: variables,
            visiting: visiting,
            budget: &budget
        )
        guard let modifier else { return rendered }
        return rendered.map { Self.applyModifier(modifier, to: $0) }
    }

    private static func applyModifier(
        _ modifier: LocaleCatalogLinkModifier, to nodes: [StoryNode]
    ) -> [StoryNode] {
        switch modifier {
        case .upper:
            return nodes.map { transformText($0) { $0.uppercased() } }
        case .lower:
            return nodes.map { transformText($0) { $0.lowercased() } }
        case .capitalize:
            var done = false
            return nodes.map { node in
                transformText(node) { text in
                    guard !done, let first = text.first else { return text }
                    done = true
                    return String(first).uppercased() + text.dropFirst()
                }
            }
        }
    }

    private static func transformText(
        _ node: StoryNode, _ transform: (String) -> String
    ) -> StoryNode {
        switch node {
        case let .text(text):
            .text(transform(text))
        case let .paragraph(children):
            .paragraph(children.map { transformText($0, transform) })
        case let .group(children):
            .group(children.map { transformText($0, transform) })
        case let .heading(level, children):
            .heading(level: level, children: children.map { transformText($0, transform) })
        case let .emphasis(style, children):
            .emphasis(style, children.map { transformText($0, transform) })
        case let .list(ordered, items):
            .list(ordered: ordered, items: items.map { $0.map { transformText($0, transform) } })
        case .lineBreak, .rule, .image, .icon:
            node
        case let .cardReference(code, children):
            .cardReference(code: code, children: children.map { transformText($0, transform) })
        case let .table(head, body):
            .table(
                head: head.map { transformRow($0, transform) },
                body: body.map { transformRow($0, transform) }
            )
        }
    }

    private static func transformRow(
        _ row: StoryTableRow, _ transform: (String) -> String
    ) -> StoryTableRow {
        StoryTableRow(cells: row.cells.map { cell in
            StoryTableCell(
                isHeader: cell.isHeader,
                children: cell.children.map { transformText($0, transform) }
            )
        })
    }

    static func losslessText(_ value: JSONValue) -> String? {
        switch value {
        case let .string(text):
            text
        case let .number(number):
            number.description
        case .null, .bool, .array, .object:
            nil
        }
    }
} // swiftlint:disable:this file_length
