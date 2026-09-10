import Foundation

/// The typed, safe presentation tree a catalog entry renders to.
///
/// Nothing here can carry HTML, CSS, a script, or a catalog-selected URL. An `image` is a
/// semantic asset reference bound to the separately validated deployment asset source, a card
/// reference carries only a card code, and every text position holds already-substituted
/// literal text. Catalog paths can only select validated files inside closed artwork families.
indirect enum StoryNode: Sendable, Equatable {
    case text(String)
    case paragraph([StoryNode])
    case group([StoryNode])
    case heading(level: Int, children: [StoryNode])
    case emphasis(LocaleCatalogEmphasis, [StoryNode])
    case list(ordered: Bool, items: [[StoryNode]])
    case lineBreak
    case rule
    /// A semantic asset reference resolved through this client's own native asset semantics.
    case image(StoryAssetReference)
    /// An icon placeholder the deployment's own `replaceIcons()` would render as a glyph
    /// (`{skull}`, `{elderThing}`, a homebrew icon). Carried as the icon's *name*, never as a
    /// raw `{name}` placeholder and never as an arbitrary URL, so the native presentation can
    /// choose its own glyph and spoken label.
    case icon(String)
    /// Text naming a card. `code` is the catalog's own card code, kept verbatim so the native
    /// card-art path can use the identifier this deployment publishes.
    case cardReference(code: String, children: [StoryNode])
    case table(head: [StoryTableRow], body: [StoryTableRow])
}

/// A semantic reference to artwork on the deployment's validated asset source.
struct StoryAssetReference: Sendable, Equatable, Hashable {
    let role: LocaleCatalogAssetRole
    /// Relative to `/img/arkham/`; revalidated by `assetKey` before any representation or fetch.
    let assetPath: String
    let alt: String?
    let source: AssetSourceNamespace?

    init(
        role: LocaleCatalogAssetRole, assetPath: String, alt: String?,
        source: AssetSourceNamespace? = nil
    ) {
        self.role = role
        self.assetPath = assetPath
        self.alt = alt
        self.source = source
    }

    var assetKey: AssetKey? {
        guard let source,
              let image = CatalogImageAsset(role: role, assetPath: assetPath)
        else { return nil }
        return AssetKey(source: source, category: .catalogImage(image))
    }

    var hasMeaningfulAccessibleDescription: Bool {
        explicitAccessibleDescription != nil || inferredEncounterSetDescription != nil
    }

    var accessibleDescription: String {
        if let explicitAccessibleDescription {
            return explicitAccessibleDescription
        }
        if let inferredEncounterSetDescription {
            return inferredEncounterSetDescription
        }
        switch role {
        case .encounterSet: return "Encounter set"
        case .card: return "Card image"
        case .token: return "Token"
        case .chaosToken: return "Chaos token"
        case .campaign: return "Campaign image"
        case .homebrew: return "Homebrew image"
        case .extra, .other: return "Game image"
        }
    }

    private var explicitAccessibleDescription: String? {
        guard let alt else { return nil }
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : alt
    }

    /// Encounter-set filenames are a closed, descriptive family used as symbols beside
    /// already-readable set names. Other image families can contain instructional diagrams
    /// and therefore require authored alternatives instead of a generic role label.
    private var inferredEncounterSetDescription: String? {
        guard role == .encounterSet,
              let image = CatalogImageAsset(role: role, assetPath: assetPath),
              let filename = image.segments.last,
              let dot = filename.lastIndex(of: ".")
        else { return nil }
        let stem = filename[..<dot]
        let words = stem.split { $0 == "-" || $0 == "_" }
        guard !words.isEmpty else { return nil }
        let label = words.map { word in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + String(word.dropFirst())
        }.joined(separator: " ")
        return label.isEmpty ? nil : "\(label) encounter set symbol"
    }
}

struct StoryTableRow: Sendable, Equatable {
    let cells: [StoryTableCell]
}

struct StoryTableCell: Sendable, Equatable {
    let isHeader: Bool
    let children: [StoryNode]
}

extension StoryNode {
    /// A plain-text projection, used where the presentation genuinely has only a string to
    /// show (a story title) and only when ``losesInstructionWhenFlattened`` is `false`.
    var plainText: String {
        switch self {
        case let .text(text): text
        case let .paragraph(children), let .group(children): children.map(\.plainText).joined()
        case let .heading(_, children): children.map(\.plainText).joined()
        case let .emphasis(_, children): children.map(\.plainText).joined()
        case let .cardReference(_, children): children.map(\.plainText).joined()
        case let .list(_, items): items.map { $0.map(\.plainText).joined() }.joined(separator: " ")
        case .lineBreak: " "
        case let .icon(name): StoryNode.spokenIconLabel(name)
        case let .image(reference): reference.accessibleDescription
        case .rule, .table: ""
        }
    }

    /// Whether flattening this node to plain text would drop an instruction.
    ///
    /// A list, a rule, an image, or a table *is* an instruction in this game's prose (the
    /// Dream-Eaters epilogue matrix is explicitly called out by the catalog as structure that
    /// must survive), so a field with nowhere to put one must fail closed rather than render
    /// a lossy string.
    var losesInstructionWhenFlattened: Bool {
        switch self {
        case .text, .lineBreak, .icon: false
        case .rule, .image, .table, .list: true
        case let .paragraph(children), let .group(children):
            children.contains { $0.losesInstructionWhenFlattened }
        case let .heading(_, children), let .emphasis(_, children):
            children.contains { $0.losesInstructionWhenFlattened }
        case let .cardReference(_, children):
            children.contains { $0.losesInstructionWhenFlattened }
        }
    }

    /// A spoken label for an icon placeholder, derived mechanically from the icon's own
    /// camelCase name (`elderThing` -> "elder thing"). Never the raw `{name}` placeholder, and
    /// never invented prose.
    static func spokenIconLabel(_ name: String) -> String {
        BoardDisplayFormatting.humanizeTag(name).lowercased()
    }
}
