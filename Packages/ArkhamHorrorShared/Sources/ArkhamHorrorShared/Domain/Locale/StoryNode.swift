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
    /// A catalog variable whose value is a typed icon name proven by the backend extractor.
    /// Only the closed token/skill values this client knows become this node; unknown future
    /// values fail the whole entry closed instead of showing raw enum text.
    case semanticIcon(StoryIcon)
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
        return trimmed.isEmpty ? nil : trimmed
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
        case let .semanticIcon(icon): icon.accessibilityLabel
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
        case .text, .lineBreak, .icon, .semanticIcon: false
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

/// Typed icon-variable values from the locale catalog. The pinned catalog has no localized
/// token, skill, or seal *names* today; accessibility labels are therefore derived
/// mechanically from the backend enum values, matching the board's existing `humanizeTag`
/// token labels rather than hard-coding display prose.
enum StoryIcon: Sendable, Equatable, Hashable {
    case chaosToken(ChaosTokenArtFace)
    case skill(StorySkillIcon)
    case seal(StorySealIcon)

    static func iconVariableValue(_ value: String) -> StoryIcon? {
        if let chaosToken = ChaosTokenArtFace.iconVariableValue(value) {
            return .chaosToken(chaosToken)
        }
        if let skill = StorySkillIcon(rawValue: value) {
            return .skill(skill)
        }
        if let seal = StorySealIcon(rawValue: value) {
            return .seal(seal)
        }
        return nil
    }

    var accessibilityLabel: String {
        switch self {
        case let .chaosToken(face):
            StoryNode.spokenIconLabel(face.catalogIconName)
        case let .skill(skill):
            StoryNode.spokenIconLabel(skill.rawValue)
        case let .seal(seal):
            StoryNode.spokenIconLabel(seal.rawValue)
        }
    }

    var systemImage: String {
        switch self {
        case .chaosToken:
            "circle.hexagongrid.fill"
        case let .skill(skill):
            skill.systemImage
        case let .seal(seal):
            seal.systemImage
        }
    }
}

private extension ChaosTokenArtFace {
    // swiftlint:disable:next cyclomatic_complexity
    static func iconVariableValue(_ value: String) -> ChaosTokenArtFace? {
        switch value {
        case "skull": .skull
        case "cultist": .cultist
        case "tablet": .tablet
        case "elderThing": .elderThing
        case "autoFail": .autoFail
        case "elderSign": .elderSign
        case "curse": .curse
        case "bless": .bless
        case "frost": .frost
        case "blood": .blood
        default: nil
        }
    }

    var catalogIconName: String {
        switch self {
        case .elderThing: "elderThing"
        case .autoFail: "autoFail"
        case .elderSign: "elderSign"
        case .skull, .cultist, .tablet, .curse, .bless, .frost, .blood:
            rawValue
        case .plusOne, .zero, .minusOne, .minusTwo, .minusThree, .minusFour, .minusFive,
             .minusSix, .minusSeven, .minusEight, .blank:
            rawValue
        }
    }
}

enum StorySkillIcon: String, Sendable, Equatable, Hashable {
    case willpower
    case intellect
    case combat
    case agility
    case wild

    var systemImage: String {
        switch self {
        case .willpower: "brain.head.profile"
        case .intellect: "magnifyingglass"
        case .combat: "burst.fill"
        case .agility: "figure.run"
        // Mirrors the web's `wild` -> `wild-icon` mapping in `frontend/src/arkham/icons.ts`.
        case .wild: "star.fill"
        }
    }
}

enum StorySealIcon: String, Sendable, Equatable, Hashable {
    case sealA
    case sealB
    case sealC
    case sealD
    case sealE

    var systemImage: String {
        switch self {
        // Mirrors the web's `sealA`...`sealE` -> `seal-a-icon`...`seal-e-icon` mapping
        // in `frontend/src/arkham/icons.ts`, using the app's SF Symbols inline-glyph path.
        case .sealA: "a.circle.fill"
        case .sealB: "b.circle.fill"
        case .sealC: "c.circle.fill"
        case .sealD: "d.circle.fill"
        case .sealE: "e.circle.fill"
        }
    }
}
