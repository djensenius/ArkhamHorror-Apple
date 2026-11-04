// swiftlint:disable file_length
import Foundation

/// The web's named inline icons: every `iconClasses` key from fork commit
/// 858b8a094611a766ed3e7b6ecc6168ab331feb17 `frontend/src/arkham/icons.ts:12-45`, plus the
/// homebrew `{moon}` icon (`frontend/homebrew/*/icons.json`, no web-font glyph). Any other
/// braced name (for example `{neutral}` or `{future}`) is not an icon and stays literal, as
/// it does on the web.
///
/// `{moon}` deliberately keeps the honest fallback (an SF Symbol plus the spoken name
/// "moon") instead of the web's artwork. On the web it comes from the Circus Ex Mortis
/// homebrew (`frontend/homebrew/circus-ex-mortis/icons.json`, `style.css:5-16`): a CSS mask
/// over `./img/icons/moon.png` that Vite emits as a hashed bundle asset
/// (`frontend/src/arkham/homebrewAssets.ts:4-8`), so there is no font glyph and no stable
/// asset URL to load at runtime. The image's licence is unknown, and this client vendors no
/// image bytes (`Resources/AssetDigests/PROVENANCE.md`).
enum WebIconName: String, CaseIterable, Sendable {
    case action, fast, reaction
    case willpower, intellect, combat, agility, wild
    case guardian, seeker, rogue, mystic, survivor
    case elderSign, autoFail, skull, cultist, tablet, elderThing
    case bless, curse, frost, blood
    case sealA, sealB, sealC, sealD, sealE
    case codex, day, night, perPlayer
    case moon
}

/// One inline icon placeholder in a raw label: a named web icon or a rune (`{runeM}` or
/// `[tdc_rune_m]`, `icons.ts:49,56`).
enum WebIconPlaceholder: Sendable, Equatable, Hashable {
    case named(WebIconName)
    /// An uppercase ASCII rune letter, `A`-`Z`.
    case rune(Character)

    /// Parses a braced placeholder name: a ``WebIconName`` raw value or `runeX` with an
    /// uppercase `X`, exactly like the web's `{rune([A-Z])}`.
    init?(placeholderName name: String) {
        if let named = WebIconName(rawValue: name) {
            self = .named(named)
            return
        }
        guard name.count == 5, name.hasPrefix("rune"), let letter = name.last,
              letter.isASCII, letter.isUppercase
        else { return nil }
        self = .rune(letter)
    }

    /// The ``StoryIconGlyph`` key; runes use the web's `rune-X` class name.
    var glyphKey: String {
        switch self {
        case let .named(name): name.rawValue
        case let .rune(letter): "rune-\(letter)"
        }
    }

    /// Chaos, skill and seal icons keep their typed ``StoryIcon`` node (and its SF Symbol
    /// fallback); every other icon is a named glyph node.
    var node: StoryNode {
        if case let .named(name) = self, let icon = StoryIcon.iconVariableValue(name.rawValue) {
            return .semanticIcon(icon)
        }
        return .icon(glyphKey)
    }
}

/// Shared inline parsing for server-provided button labels that still contain the web's
/// literal `{iconName}` placeholders. Catalog-rendered story text already arrives as nodes;
/// this parser exists only for non-catalog label strings. It follows the web's
/// `formatContent` (fork `frontend/src/arkham/helpers.ts:229-246`) in order: icons and both
/// rune forms, then `_bold_`, then `*italic*`, then `[^N]` footnote references, then the
/// `{asterisk}` -> `*` and `{underscore}` -> `_` escapes. Raw labels follow the web's
/// unescaped `replaceIcons`, so `{{skull}}` renders as a literal `{`, the skull icon, and a
/// literal `}`.
///
/// One deliberate difference: an underscore inside a word (`a_b`, `tdc_rune_m`) never opens
/// or closes bold, so identifiers stay literal.
enum StoryIconInlineParser {
    /// Inline nodes for `text`, or `nil` when it has no icon, emphasis or footnote (the plain
    /// title then renders as is).
    static func nodes(for text: String) -> [StoryNode]? {
        let atoms = formattedAtoms(text)
        guard atoms.contains(where: \.isMarkup) else { return nil }
        let nodes = trimmingTextEdges(storyNodes(atoms))
        return nodes.isEmpty ? nil : nodes
    }

    /// ``nodes(for:)`` for one text run among other nodes: edge whitespace is kept, plain
    /// text stays one `.text` node, and each icon becomes `iconNode(placeholder)`.
    static func runNodes(
        for text: String,
        iconNode: (WebIconPlaceholder) -> StoryNode
    ) -> [StoryNode] {
        storyNodes(formattedAtoms(text), iconNode: iconNode)
    }

    /// Whether `text` still holds an unrendered web placeholder: a braced or bracketed icon,
    /// the `{asterisk}` / `{underscore}` escape, or a `[^N]` footnote reference. Catalog
    /// choice-label text has none (its `[^N]` is already split into markers); a text
    /// variable value may, and then the label is left unsplit for this parser.
    static func containsRawPlaceholder(_ text: String) -> Bool {
        // Flat icon atoms hold no emphasis, so any markup atom is an icon or a footnote.
        unescaped(text) != text || footnoted(iconAtoms(text)).contains(where: \.isMarkup)
    }

    /// Removing markers can leave whitespace at the edges (`__ Hello`), so the outer text
    /// nodes are trimmed to match the trimmed title.
    private static func trimmingTextEdges(_ nodes: [StoryNode]) -> [StoryNode] {
        var nodes = nodes
        if case let .text(text)? = nodes.first {
            let trimmed = String(text.drop(while: \.isWhitespace))
            if trimmed.isEmpty {
                nodes.removeFirst()
            } else {
                nodes[0] = .text(trimmed)
            }
        }
        if case let .text(text)? = nodes.last {
            let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
            if trimmed.isEmpty {
                nodes.removeLast()
            } else {
                nodes[nodes.count - 1] = .text(trimmed)
            }
        }
        return nodes
    }

    /// The spoken/plain form of `text`: the same formatting as ``nodes(for:)`` with each
    /// icon replaced by its spoken name, emphasis markers removed and each footnote
    /// reference reduced to its number.
    static func plainText(
        for text: String,
        spokenName: (WebIconPlaceholder) -> String
    ) -> String {
        plainText(formattedAtoms(text), spokenName: spokenName, footnote: { $0 })
    }

    /// The VoiceOver form of ``plainText(for:spokenName:)``: each footnote reference is
    /// announced as a separate " footnote N" (``StoryNode/spokenFootnote(_:)``), so
    /// `1927[^5]` reads "1927 footnote 5" rather than "19275". Use it for accessibility
    /// labels only; displayed titles keep the plain projection.
    static func spokenText(
        for text: String,
        spokenName: (WebIconPlaceholder) -> String
    ) -> String {
        plainText(
            formattedAtoms(text), spokenName: spokenName, footnote: StoryNode.spokenFootnote
        )
    }

    private indirect enum Atom {
        case character(Character)
        case icon(WebIconPlaceholder)
        case emphasis(LocaleCatalogEmphasis, [Atom])
        case footnote(String)

        var isMarkup: Bool {
            if case .character = self {
                return false
            }
            return true
        }

        func isCharacter(_ character: Character) -> Bool {
            if case let .character(value) = self {
                return value == character
            }
            return false
        }

        var isWordCharacter: Bool {
            if case let .character(value) = self {
                return value.isLetter || value.isNumber
            }
            return false
        }
    }

    private static func formattedAtoms(_ text: String) -> [Atom] {
        footnoted(italicized(
            emphasized(iconAtoms(text), delimiter: "_", style: .bold, intraword: false)
        ))
    }

    /// The web's `/\[\^(\d+)\]/g` -> `<sup class="footnote-ref">`, applied after emphasis.
    private static func footnoted(_ atoms: [Atom]) -> [Atom] {
        var result: [Atom] = []
        var index = 0
        while index < atoms.count {
            if case let .emphasis(style, children) = atoms[index] {
                result.append(.emphasis(style, footnoted(children)))
                index += 1
            } else if let marker = StoryNode.footnoteMarker(at: index, character: { position in
                guard atoms.indices.contains(position),
                      case let .character(character) = atoms[position] else { return nil }
                return character
            }) {
                result.append(.footnote(marker.number))
                index += marker.length
            } else {
                result.append(atoms[index])
                index += 1
            }
        }
        return result
    }

    private static func iconAtoms(_ text: String) -> [Atom] {
        let characters = Array(text)
        var atoms: [Atom] = []
        var index = 0
        while index < characters.count {
            if let (placeholder, length) = placeholder(in: characters, at: index) {
                atoms.append(.icon(placeholder))
                index += length
            } else {
                atoms.append(.character(characters[index]))
                index += 1
            }
        }
        return atoms
    }

    private static let runeTokenPrefix = Array("[tdc_rune_")

    /// The longest braced name ``WebIconPlaceholder(placeholderName:)`` accepts: a
    /// ``WebIconName`` or `runeX`.
    static let maxPlaceholderNameLength = WebIconName.allCases
        .map(\.rawValue.count)
        .reduce("runeX".count, max)

    private static func placeholder(
        in characters: [Character],
        at index: Int
    ) -> (WebIconPlaceholder, Int)? {
        switch characters[index] {
        case "{":
            // No placeholder name is longer than `maxPlaceholderNameLength`, so the search
            // for `}` is bounded and a long run of `{` stays linear.
            let searchEnd = min(characters.count, index + maxPlaceholderNameLength + 2)
            guard index + 1 < searchEnd,
                  let close = characters[(index + 1) ..< searchEnd].firstIndex(of: "}"),
                  let placeholder = WebIconPlaceholder(
                      placeholderName: String(characters[(index + 1) ..< close])
                  )
            else { return nil }
            return (placeholder, close - index + 1)
        case "[":
            let letterIndex = index + runeTokenPrefix.count
            guard letterIndex + 1 < characters.count,
                  Array(characters[index ..< letterIndex]) == runeTokenPrefix,
                  characters[letterIndex + 1] == "]",
                  characters[letterIndex].isASCII, characters[letterIndex].isLetter,
                  let letter = characters[letterIndex].uppercased().first
            else { return nil }
            return (.rune(letter), runeTokenPrefix.count + 2)
        default:
            return nil
        }
    }

    /// Pairs each delimiter with the next one, like the web's `_([^_]*)_` and
    /// `\*([^\*]*)\*`. When `intraword` is `false`, a pair whose opener follows a letter or
    /// digit, or whose closer precedes one, is literal.
    private static func emphasized(
        _ atoms: [Atom],
        delimiter: Character,
        style: LocaleCatalogEmphasis,
        intraword: Bool
    ) -> [Atom] {
        var result: [Atom] = []
        var index = 0
        while index < atoms.count {
            guard atoms[index].isCharacter(delimiter),
                  let close = atoms[(index + 1)...].firstIndex(where: {
                      $0.isCharacter(delimiter)
                  }),
                  intraword || !(
                      (index > 0 && atoms[index - 1].isWordCharacter)
                          || (close + 1 < atoms.count && atoms[close + 1].isWordCharacter)
                  )
            else {
                result.append(atoms[index])
                index += 1
                continue
            }
            result.append(.emphasis(style, Array(atoms[(index + 1) ..< close])))
            index = close + 1
        }
        return result
    }

    private static func italicized(_ atoms: [Atom]) -> [Atom] {
        let nested = atoms.map { atom -> Atom in
            if case let .emphasis(style, children) = atom {
                return .emphasis(style, italicized(children))
            }
            return atom
        }
        return emphasized(nested, delimiter: "*", style: .italic, intraword: true)
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "{asterisk}", with: "*")
            .replacingOccurrences(of: "{underscore}", with: "_")
    }

    private static func storyNodes(
        _ atoms: [Atom],
        iconNode: (WebIconPlaceholder) -> StoryNode = { $0.node }
    ) -> [StoryNode] {
        var nodes: [StoryNode] = []
        var buffer = ""
        for atom in atoms {
            switch atom {
            case let .character(character):
                buffer.append(character)
                continue
            case let .icon(placeholder):
                appendText(unescaped(buffer), to: &nodes)
                nodes.append(iconNode(placeholder))
            case let .emphasis(style, children):
                appendText(unescaped(buffer), to: &nodes)
                let inner = storyNodes(children, iconNode: iconNode)
                if !inner.isEmpty {
                    nodes.append(.emphasis(style, inner))
                }
            case let .footnote(number):
                appendText(unescaped(buffer), to: &nodes)
                nodes.append(.footnoteMarker(number))
            }
            buffer = ""
        }
        appendText(unescaped(buffer), to: &nodes)
        return nodes
    }

    private static func plainText(
        _ atoms: [Atom],
        spokenName: (WebIconPlaceholder) -> String,
        footnote: (String) -> String
    ) -> String {
        var result = ""
        var buffer = ""
        for atom in atoms {
            switch atom {
            case let .character(character):
                buffer.append(character)
                continue
            case let .icon(placeholder):
                result += unescaped(buffer) + spokenName(placeholder)
            case let .emphasis(_, children):
                result += unescaped(buffer)
                    + plainText(children, spokenName: spokenName, footnote: footnote)
            case let .footnote(number):
                result += unescaped(buffer) + footnote(number)
            }
            buffer = ""
        }
        return result + unescaped(buffer)
    }

    private static func appendText(_ text: String, to nodes: inout [StoryNode]) {
        guard !text.isEmpty else { return }
        if case let .text(existing)? = nodes.last {
            nodes[nodes.count - 1] = .text(existing + text)
        } else {
            nodes.append(.text(text))
        }
    }
}

extension ChaosTokenFace {
    var storyIcon: StoryIcon? {
        chaosTokenArtFace.flatMap { face in
            StoryIconGlyph.byIconName[face.catalogIconName] == nil ? nil : .chaosToken(face)
        }
    }

    private var chaosTokenArtFace: ChaosTokenArtFace? {
        if self == .skull {
            return .skull
        }
        if self == .cultist {
            return .cultist
        }
        if self == .tablet {
            return .tablet
        }
        if self == .elderThing {
            return .elderThing
        }
        if self == .autoFail {
            return .autoFail
        }
        if self == .elderSign {
            return .elderSign
        }
        if self == .curseToken {
            return .curse
        }
        if self == .blessToken {
            return .bless
        }
        if self == .frostToken {
            return .frost
        }
        if self == .bloodToken {
            return .blood
        }
        return nil
    }
}
