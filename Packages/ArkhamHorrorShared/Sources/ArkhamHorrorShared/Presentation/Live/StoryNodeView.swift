// swiftlint:disable file_length
import SwiftUI

enum StoryNodeFlowItem: Equatable {
    case inline([StoryNode])
    case block(StoryNode)
}

enum StoryNodePresentation {
    static func flow(_ nodes: [StoryNode]) -> [StoryNodeFlowItem] {
        var items: [StoryNodeFlowItem] = []
        var inline: [StoryNode] = []
        func flushInline() {
            guard !inline.isEmpty else { return }
            items.append(.inline(inline))
            inline.removeAll(keepingCapacity: true)
        }
        for node in nodes {
            if isInline(node) {
                inline.append(node)
            } else {
                flushInline()
                items.append(.block(node))
            }
        }
        flushInline()
        return items
    }

    static func accessibilityLabel(for nodes: [StoryNode]) -> String {
        nodes.map(\.plainText).joined()
    }

    static func encounterSetGroupReferences(_ children: [StoryNode]) -> [StoryAssetReference]? {
        let references = children.compactMap { child -> StoryAssetReference? in
            guard case let .image(reference) = child, reference.role == .encounterSet else {
                return nil
            }
            return reference
        }
        return references.count == children.count && !references.isEmpty ? references : nil
    }

    static func isInline(_ node: StoryNode) -> Bool {
        switch node {
        case .text, .lineBreak, .icon, .semanticIcon:
            true
        case let .group(children), let .emphasis(_, children),
             let .cardReference(_, children):
            children.allSatisfy(isInline)
        case .paragraph, .heading, .list, .rule, .image, .table:
            false
        }
    }
}

/// Renders a single ``ResolvedStoryEntry``: every entry reaching this view already went
/// through ``StoryNarrativeLocalization`` so `.text` is either resolved catalog prose,
/// literal server text, or a readable server-key fallback.
struct ResolvedStoryEntryView: View {
    let entry: ResolvedStoryEntry
    var cardCatalog: CardCatalogSnapshot?

    var body: some View {
        switch entry {
        case let .text(text):
            Text(text)
        case let .nodes(nodes):
            StoryNodeSequenceView(nodes: nodes)
        case let .heading(level, nodes):
            StoryNodeChildrenView(children: nodes)
                .font(StoryHeadingPresentation.font(for: level.rawValue))
                .addingStoryHeadingTrait()
        case let .modified(modifiers, entry):
            ModifiedResolvedStoryEntryView(
                modifiers: modifiers, entry: entry, cardCatalog: cardCatalog
            )
        case let .composite(entries):
            ResolvedStoryEntryGroupView(entries: entries, cardCatalog: cardCatalog)
        case let .columns(entries):
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    ResolvedStoryEntryView(entry: entry, cardCatalog: cardCatalog)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ResolvedStoryListItemView(item: item, cardCatalog: cardCatalog)
                }
            }
        case let .cardReference(cardCode, _):
            StoryReferenceText(
                title: cardCatalog?.displayName(for: cardCode) ?? "Card \(cardCode.rawValue)"
            )
        case let .tarotReference(arcana):
            StoryReferenceText(title: "Tarot \(arcana)")
        case let .chaosTokenReference(face):
            StoryReferenceText(title: "Chaos token \(face.rawValue)")
        case let .chaosTokenMorph(from, target):
            StoryReferenceText(title: "Chaos token \(from.rawValue) → \(target.rawValue)")
        case .divider:
            Divider()
        }
    }
}

private struct ResolvedStoryEntryGroupView: View {
    let entries: [ResolvedStoryEntry]
    var cardCatalog: CardCatalogSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                ResolvedStoryEntryView(entry: entry, cardCatalog: cardCatalog)
            }
        }
    }
}

private struct ModifiedResolvedStoryEntryView: View {
    let modifiers: [FlavorTextModifier]
    let entry: ResolvedStoryEntry
    var cardCatalog: CardCatalogSnapshot?

    private var status: StoryFlavorEntryStatus? {
        StoryFlavorEntryStatus.status(for: modifiers)
    }

    var body: some View {
        if let status {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.markerColor)
                    .accessibilityLabel(status.accessibilityLabel)
                ResolvedStoryEntryView(entry: entry, cardCatalog: cardCatalog)
                    .modifier(StoryFlavorTextModifier(modifiers: modifiers))
            }
            .accessibilityElement(children: .combine)
        } else {
            ResolvedStoryEntryView(entry: entry, cardCatalog: cardCatalog)
                .modifier(StoryFlavorTextModifier(modifiers: modifiers))
        }
    }
}

enum StoryFlavorEntryStatus: Equatable {
    case valid
    case invalid

    var systemImage: String {
        switch self {
        case .valid: "checkmark.circle.fill"
        case .invalid: "xmark.circle.fill"
        }
    }

    var markerColor: Color {
        switch self {
        case .valid: .green
        case .invalid: .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .valid:
            CampaignPromptLocalization.localized("story.entryStatus.valid", "Valid")
        case .invalid:
            CampaignPromptLocalization.localized("story.entryStatus.invalid", "Invalid")
        }
    }

    static func status(for modifiers: [FlavorTextModifier]) -> StoryFlavorEntryStatus? {
        if modifiers.contains(.invalidEntry) {
            return .invalid
        }
        if modifiers.contains(.validEntry) {
            return .valid
        }
        return nil
    }
}

private struct StoryReferenceText: View {
    let title: String
    var detail: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct StoryFlavorTextModifier: ViewModifier {
    let modifiers: [FlavorTextModifier]

    func body(content: Content) -> some View {
        content
            .modifier(StoryOptionalForegroundStyleModifier(foregroundStyle: foregroundStyle))
            .font(font)
            .multilineTextAlignment(alignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(padding)
            .background(background)
            .overlay(border)
    }

    private var foregroundStyle: Color? {
        if modifiers.contains(.invalidEntry) {
            return .secondary
        }
        if modifiers.contains(.redEntry) {
            return .red
        }
        if modifiers.contains(.greenEntry) {
            return .green
        }
        if modifiers.contains(.blueEntry) {
            return .blue
        }
        if modifiers.contains(.hauntedEntry) {
            return .purple
        }
        return nil
    }

    private var font: Font? {
        if modifiers.contains(.plainText) {
            return .body
        }
        if modifiers.contains(.checkpointEntry) || modifiers.contains(.resolutionEntry) {
            return .headline
        }
        return nil
    }

    private var alignment: TextAlignment {
        if modifiers.contains(.rightAligned) {
            return .trailing
        }
        if modifiers.contains(.centeredEntry) {
            return .center
        }
        return .leading
    }

    private var frameAlignment: Alignment {
        if modifiers.contains(.rightAligned) {
            return .trailing
        }
        if modifiers.contains(.centeredEntry) {
            return .center
        }
        return .leading
    }

    private var padding: CGFloat {
        modifiers.contains(.borderedEntry) || modifiers.contains(.codexEntry)
            || modifiers.contains(.interludeEntry) ? 8 : 0
    }

    @ViewBuilder
    private var background: some View {
        if modifiers.contains(.codexEntry) || modifiers.contains(.interludeEntry) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ArkhamTheme.accent.opacity(0.12))
        } else if modifiers.contains(.tokenRevealEntry) || modifiers.contains(.byDifficultyEntry) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    @ViewBuilder
    private var border: some View {
        if modifiers.contains(.borderedEntry) || modifiers.contains(.codexEntry) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ArkhamTheme.accent.opacity(0.7), lineWidth: 1)
        }
    }
}

private struct StoryOptionalForegroundStyleModifier: ViewModifier {
    let foregroundStyle: Color?

    func body(content: Content) -> some View {
        if let foregroundStyle {
            content.foregroundStyle(foregroundStyle)
        } else {
            content
        }
    }
}

private struct ResolvedStoryListItemView: View {
    let item: ResolvedStoryListItem
    var cardCatalog: CardCatalogSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                ResolvedStoryEntryView(entry: item.entry, cardCatalog: cardCatalog)
            }
            if !item.nested.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.nested.enumerated()), id: \.offset) { _, nested in
                        ResolvedStoryListItemView(item: nested, cardCatalog: cardCatalog)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

private struct StoryNodeSequenceView: View {
    let nodes: [StoryNode]

    var body: some View {
        let flow = StoryNodePresentation.flow(nodes)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(flow.enumerated()), id: \.offset) { _, item in
                switch item {
                case let .inline(nodes):
                    StoryInlineTextView(nodes: nodes)
                case let .block(node):
                    StoryNodeView(node: node)
                }
            }
        }
    }
}

private struct StoryNodeChildrenView: View {
    let children: [StoryNode]

    var body: some View {
        if children.allSatisfy(StoryNodePresentation.isInline) {
            StoryInlineTextView(nodes: children)
        } else {
            StoryNodeSequenceView(nodes: children)
        }
    }
}

private struct StoryInlineTextView: View {
    let nodes: [StoryNode]

    var body: some View {
        if let text = StoryInlineTextRenderer.text(for: nodes) {
            text.accessibilityLabel(StoryNodePresentation.accessibilityLabel(for: nodes))
        }
    }
}

private enum StoryInlineTextRenderer {
    static func text(for nodes: [StoryNode]) -> Text? {
        var result = Text("")
        for node in nodes {
            guard let fragment = text(for: node) else { return nil }
            result = Text("\(result)\(fragment)")
        }
        return result
    }

    private static func text(for node: StoryNode) -> Text? {
        switch node {
        case let .text(text):
            Text(verbatim: text)
        case let .group(children):
            text(for: children)
        case let .emphasis(style, children):
            text(for: children).map { emphasized($0, style: style) }
        case .lineBreak:
            Text("\n")
        case let .icon(name):
            Text(
                "\(Image(systemName: "seal.fill")) \(StoryNode.spokenIconLabel(name))"
            )
        case let .semanticIcon(icon):
            Text(Image(systemName: icon.systemImage))
        case let .cardReference(_, children):
            text(for: children).map {
                Text(
                    "\(Image(systemName: "rectangle.portrait.on.rectangle.portrait")) \($0)"
                )
            }
        case .paragraph, .heading, .list, .rule, .image, .table:
            nil
        }
    }

    private static func emphasized(_ text: Text, style: LocaleCatalogEmphasis) -> Text {
        switch style {
        case .bold: text.bold()
        case .italic: text.italic()
        case .underline: text.underline()
        case .strikethrough: text.strikethrough()
        case .small: text.font(.caption)
        case .smallCaps: text.font(.caption.smallCaps())
        }
    }
}

private struct StoryNodeView: View {
    let node: StoryNode

    var body: some View {
        switch node {
        case .text, .lineBreak, .icon, .semanticIcon:
            StoryInlineTextView(nodes: [node])
        case let .paragraph(children):
            StoryNodeChildrenView(children: children)
        case let .group(children):
            if let references = StoryNodePresentation.encounterSetGroupReferences(children) {
                StoryEncounterSetGroupView(references: references)
            } else {
                StoryNodeChildrenView(children: children)
            }
        case let .heading(level, children):
            StoryNodeChildrenView(children: children)
                .font(StoryHeadingPresentation.font(for: level))
                .addingStoryHeadingTrait()
        case let .emphasis(style, children):
            emphasized(children, style: style)
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                        StoryNodeChildrenView(children: item)
                    }
                }
            }
        case .rule:
            Divider()
        case let .image(reference):
            StoryAssetImageView(reference: reference)
        case let .cardReference(code, children):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                StoryNodeChildrenView(children: children)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardReferenceLabel(code: code, children: children))
        case let .table(head, body):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(head.enumerated()), id: \.offset) { _, row in
                    StoryTableRowView(row: row)
                        .fontWeight(.semibold)
                }
                ForEach(Array(body.enumerated()), id: \.offset) { _, row in
                    StoryTableRowView(row: row)
                }
            }
        }
    }

    @ViewBuilder
    private func emphasized(
        _ children: [StoryNode], style: LocaleCatalogEmphasis
    ) -> some View {
        switch style {
        case .bold:
            StoryNodeChildrenView(children: children).fontWeight(.bold)
        case .italic:
            StoryNodeChildrenView(children: children).italic()
        case .underline:
            StoryNodeChildrenView(children: children).underline()
        case .strikethrough:
            StoryNodeChildrenView(children: children).strikethrough()
        case .small:
            StoryNodeChildrenView(children: children).font(.caption)
        case .smallCaps:
            StoryNodeChildrenView(children: children).font(.caption.smallCaps())
        }
    }

    private func cardReferenceLabel(code: String, children: [StoryNode]) -> String {
        let label = StoryNodePresentation.accessibilityLabel(for: children)
        return label.isEmpty ? "Card \(code)" : label
    }
}

private struct StoryEncounterSetGroupView: View {
    let references: [StoryAssetReference]

    var body: some View {
        StoryCenteredWrappingRowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                StoryEncounterSetIconView(reference: reference)
                    .accessibilityLabel(reference.accessibleDescription)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(references.map(\.accessibleDescription).joined(separator: ", "))
    }
}

private struct StoryEncounterSetIconView: View {
    let reference: StoryAssetReference
    @Environment(\.storyAssetCache) private var cacheService

    var body: some View {
        if reference.assetKey != nil, cacheService != nil {
            StoryAssetImageView(reference: reference)
                .frame(width: 40, height: 40)
        } else {
            StoryAssetImageView(reference: reference)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 120, maxWidth: 180)
        }
    }
}

struct StoryCenteredWrappingRowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    static func resolvedWidth(for proposal: ProposedViewSize, measuredWidth: CGFloat) -> CGFloat {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return measuredWidth
        }
        return proposedWidth
    }

    private static func availableWidth(for proposal: ProposedViewSize) -> CGFloat {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return .infinity
        }
        return proposedWidth
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let rows = rows(in: Self.availableWidth(for: proposal), subviews: subviews)
        let measuredWidth = rows.map(\.width).max() ?? 0
        return CGSize(
            width: Self.resolvedWidth(for: proposal, measuredWidth: measuredWidth),
            height: rowsHeight(rows)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let rows = rows(in: bounds.width, subviews: subviews)
        var currentY = bounds.minY
        for row in rows {
            var currentX = bounds.minX + max(0, (bounds.width - row.width) / 2)
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: currentX, y: currentY + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                currentX += item.size.width + horizontalSpacing
            }
            currentY += row.height + verticalSpacing
        }
    }

    private func rows(in availableWidth: CGFloat, subviews: Subviews) -> [StoryWrappingRow] {
        guard !subviews.isEmpty else { return [] }
        var rows: [StoryWrappingRow] = []
        var current = StoryWrappingRow(items: [], width: 0, height: 0)
        let canWrap = availableWidth.isFinite && availableWidth > 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let item = StoryWrappingRowItem(index: index, size: size)
            let nextWidth = current.items.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width
            if canWrap, !current.items.isEmpty, nextWidth > availableWidth {
                rows.append(current)
                current = StoryWrappingRow(items: [item], width: size.width, height: size.height)
            } else {
                current.items.append(item)
                current.width = nextWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private func rowsHeight(_ rows: [StoryWrappingRow]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let contentHeight = rows.map(\.height).reduce(0, +)
        return contentHeight + verticalSpacing * CGFloat(rows.count - 1)
    }
}

private struct StoryWrappingRow {
    var items: [StoryWrappingRowItem]
    var width: CGFloat
    var height: CGFloat
}

private struct StoryWrappingRowItem {
    let index: Int
    let size: CGSize
}

private enum StoryHeadingPresentation {
    static func font(for level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }
}

private extension View {
    @ViewBuilder
    func addingStoryHeadingTrait() -> some View {
        #if os(iOS) || os(macOS) || os(visionOS)
            accessibilityAddTraits(.isHeader)
        #else
            self
        #endif
    }
}

private struct StoryTableRowView: View {
    let row: StoryTableRow

    var body: some View {
        GridRow {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                StoryNodeChildrenView(children: cell.children)
                    .gridColumnAlignment(.leading)
            }
        }
    }
}
