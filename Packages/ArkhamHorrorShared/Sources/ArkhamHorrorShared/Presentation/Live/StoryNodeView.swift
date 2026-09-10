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

    static func isInline(_ node: StoryNode) -> Bool {
        switch node {
        case .text, .lineBreak, .icon:
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
/// through ``StoryNarrativeLocalization/resolvedStory(for:vocabulary:)``, so `.text` is
/// always finished, human-readable narrative -- never a raw i18n key.
struct ResolvedStoryEntryView: View {
    let entry: ResolvedStoryEntry

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
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ResolvedStoryListItemView(item: item)
                }
            }
        }
    }
}

private struct ResolvedStoryListItemView: View {
    let item: ResolvedStoryListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                ResolvedStoryEntryView(entry: item.entry)
            }
            if !item.nested.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.nested.enumerated()), id: \.offset) { _, nested in
                        ResolvedStoryListItemView(item: nested)
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
        case .text, .lineBreak, .icon:
            StoryInlineTextView(nodes: [node])
        case let .paragraph(children), let .group(children):
            StoryNodeChildrenView(children: children)
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
