import Foundation

/// One locale/pack slice of the catalog (`frontend/schemas/locale-catalog/v1/chunk.schema.json`),
/// after complete validation against the closed v1 schema.
struct LocaleCatalogChunk: Sendable, Equatable {
    let locale: String
    let fallback: String?
    let pack: String
    let entries: [String: LocaleCatalogEntry]
}

/// A message catalog entry. The three forms are exactly the schema's `oneOf`.
enum LocaleCatalogEntry: Sendable, Equatable {
    /// A single rendered message.
    case message(nodes: [LocaleCatalogNode], variables: [LocaleCatalogVariable])
    /// One node list per vue-i18n plural branch.
    case plural(cases: [[LocaleCatalogNode]], variables: [LocaleCatalogVariable])
    /// Markup or message syntax this catalog revision refuses to reinterpret. Carries no
    /// content at all, and must be rendered as unavailable rather than blank.
    case unsupported(reason: String)
}

/// A declared placeholder. Declared, never interpolated at generation time: the backend's
/// `I18nEntry.variables` are substituted by the client, exactly as vue-i18n does for the web.
struct LocaleCatalogVariable: Sendable, Equatable, Hashable {
    enum Source: String, Sendable, Equatable, Hashable {
        /// A `{name}` placeholder supplied by `I18nEntry.variables`.
        case named
        /// A `{0}` positional placeholder.
        case list
    }

    enum Role: String, Sendable, Equatable, Hashable {
        /// Substituted verbatim.
        case text
        /// Production `replaceIcons()` renders this name as an icon glyph; the catalog
        /// preserves the placeholder instead of rendering it.
        case icon
        /// The name only ever reaches a `class`/`style`/`data-*` attribute, so a client with
        /// no value for it loses styling, never an instruction.
        case presentation
    }

    let name: String
    let source: Source
    let role: Role
}

/// The closed render-AST node vocabulary. Clients never execute HTML: there is no node here
/// that can carry markup, a script, a stylesheet, or an arbitrary URL.
indirect enum LocaleCatalogNode: Sendable, Equatable {
    /// Literal text; entities are already decoded.
    case text(String)
    /// A typed placeholder. `role` is `text` or `icon` here — a `presentation` variable never
    /// reaches a text position, only an attribute.
    case variable(name: String, source: LocaleCatalogVariable.Source, isIcon: Bool)
    /// A vue-i18n linked message (`@:key` / `@:{var}`), resolved by the client against this
    /// locale and then the fallback locale.
    case linked(target: LocaleCatalogLinkTarget, modifier: LocaleCatalogLinkModifier?)
    /// `<br>`.
    case lineBreak
    /// `<hr>`.
    case rule
    /// A block container. `isParagraph` distinguishes `paragraph` from `group`; both carry
    /// only presentation hints beyond their children.
    case block(isParagraph: Bool, children: [LocaleCatalogNode])
    case heading(level: Int, children: [LocaleCatalogNode])
    case emphasis(style: LocaleCatalogEmphasis, children: [LocaleCatalogNode])
    case list(ordered: Bool, items: [[LocaleCatalogNode]])
    /// A semantic asset reference. Never image bytes, never an absolute or external URL.
    case image(role: LocaleCatalogAssetRole, assetPath: String, alt: String?)
    /// Text that names a specific card, carrying only the card code.
    case cardReference(code: String, children: [LocaleCatalogNode])
    case table(head: [LocaleCatalogTableRow], body: [LocaleCatalogTableRow])
}

enum LocaleCatalogLinkTarget: Sendable, Equatable {
    case staticKey(String)
    case variable(name: String, source: LocaleCatalogVariable.Source)
}

enum LocaleCatalogLinkModifier: String, Sendable, Equatable {
    case upper
    case lower
    case capitalize
}

enum LocaleCatalogEmphasis: String, Sendable, Equatable, CaseIterable {
    case bold
    case italic
    case underline
    case strikethrough
    case small
    case smallCaps
}

enum LocaleCatalogAssetRole: String, Sendable, Equatable, CaseIterable {
    case encounterSet
    case card
    case token
    case chaosToken
    case campaign
    case homebrew
    case extra
    case other
}

struct LocaleCatalogTableRow: Sendable, Equatable {
    let cells: [LocaleCatalogTableCell]
}

struct LocaleCatalogTableCell: Sendable, Equatable {
    let isHeader: Bool
    let children: [LocaleCatalogNode]
}

// MARK: - Decoding

extension LocaleCatalogChunk {
    // Validates and decodes a chunk from already-parsed JSON, requiring its declared identity
    // to match exactly what the verified manifest promised.
    // swiftlint:disable:next function_parameter_count
    static func validate(
        _ value: JSONValue,
        expectedLocale: String,
        expectedFallback: String?,
        expectedPack: String,
        expectedKeys: Int,
        expectedUnsupportedKeys: Int
    ) -> Result<LocaleCatalogChunk, LocaleCatalogFailure> {
        guard case let .object(object) = value,
              Set(object.keys) == ["schemaVersion", "locale", "fallback", "pack", "entries"],
              object["schemaVersion"] == .string(LocaleCatalogLimits.schemaVersion),
              object["locale"] == .string(expectedLocale),
              object["pack"] == .string(expectedPack),
              object["fallback"] == expectedFallback.map(JSONValue.string) ?? .null,
              case let .object(rawEntries)? = object["entries"]
        else { return .failure(.malformedChunk) }
        var entries: [String: LocaleCatalogEntry] = [:]
        entries.reserveCapacity(rawEntries.count)
        for (key, rawEntry) in rawEntries {
            guard LocaleCatalogGrammar.isMessageKey(key),
                  let entry = LocaleCatalogEntry.decode(rawEntry)
            else { return .failure(.malformedChunk) }
            entries[key] = entry
        }
        let unsupportedKeys = entries.values.reduce(into: 0) { count, entry in
            if case .unsupported = entry {
                count += 1
            }
        }
        let packsMatch = entries.keys.allSatisfy {
            LocaleCatalogSnapshot.pack(for: $0) == expectedPack
        }
        guard entries.count == expectedKeys,
              unsupportedKeys == expectedUnsupportedKeys,
              packsMatch
        else {
            return .failure(.malformedChunk)
        }
        return .success(LocaleCatalogChunk(
            locale: expectedLocale,
            fallback: expectedFallback,
            pack: expectedPack,
            entries: entries
        ))
    }
}

extension LocaleCatalogEntry {
    static func decode(_ value: JSONValue) -> LocaleCatalogEntry? {
        guard case let .object(object) = value, case let .string(form)? = object["form"] else {
            return nil
        }
        switch form {
        case "message":
            guard Set(object.keys).isSubset(of: ["form", "nodes", "variables", "linkedVariables"]),
                  object["nodes"] != nil, object["variables"] != nil,
                  let nodes = LocaleCatalogNode.decodeList(object["nodes"], depth: 0),
                  let variables = decodeVariables(object["variables"]),
                  let linked = decodeOptionalVariables(object["linkedVariables"]),
                  variablesAreConsistent(variables + linked),
                  LocaleCatalogNode.referencesOnlyDeclaredVariables(
                      nodes, declarations: variables + linked
                  )
            else { return nil }
            return .message(nodes: nodes, variables: variables + linked)
        case "plural":
            guard Set(object.keys).isSubset(of: ["form", "cases", "variables", "linkedVariables"]),
                  object["cases"] != nil, object["variables"] != nil,
                  case let .array(rawCases)? = object["cases"], !rawCases.isEmpty,
                  let variables = decodeVariables(object["variables"]),
                  let linked = decodeOptionalVariables(object["linkedVariables"]),
                  variablesAreConsistent(variables + linked)
            else { return nil }
            var cases: [[LocaleCatalogNode]] = []
            cases.reserveCapacity(rawCases.count)
            for rawCase in rawCases {
                guard let nodes = LocaleCatalogNode.decodeList(rawCase, depth: 0),
                      LocaleCatalogNode.referencesOnlyDeclaredVariables(
                          nodes, declarations: variables + linked
                      )
                else {
                    return nil
                }
                cases.append(nodes)
            }
            return .plural(cases: cases, variables: variables + linked)
        case "unsupported":
            guard Set(object.keys) == ["form", "reason", "detail"],
                  case let .string(reason)? = object["reason"],
                  Self.unsupportedReasons.contains(reason),
                  case let .string(detail)? = object["detail"],
                  detail.count <= 120
            else { return nil }
            return .unsupported(reason: reason)
        default:
            return nil
        }
    }

    /// The chunk schema's closed `reason` enum. An unknown reason is a schema violation, not
    /// a new kind of unavailability to tolerate.
    static let unsupportedReasons: Set<String> = [
        "message-syntax-error", "unsupported-message-syntax", "html-parse-error",
        "unsupported-element", "unsupported-attribute", "placeholder-in-attribute",
        "asset-variable-outside-image", "unsupported-image-source", "image-path-escape",
        "invalid-style-token", "misplaced-list-item", "unresolved-link",
        "conflicting-variable-role", "invalid-style-declaration", "unsupported-link-target",
        "link-cycle", "unusable-variable-type",
    ]

    private static func decodeOptionalVariables(_ value: JSONValue?) -> [LocaleCatalogVariable]? {
        guard let value else { return [] }
        return decodeVariables(value)
    }

    private static func decodeVariables(_ value: JSONValue?) -> [LocaleCatalogVariable]? {
        guard case let .array(elements)? = value,
              elements.count <= LocaleCatalogLimits.maxVariablesPerEntry
        else { return nil }
        var variables: [LocaleCatalogVariable] = []
        variables.reserveCapacity(elements.count)
        for element in elements {
            guard case let .object(object) = element,
                  Set(object.keys) == ["name", "source", "role"],
                  case let .string(name)? = object["name"],
                  LocaleCatalogGrammar.isVariableName(name),
                  case let .string(rawSource)? = object["source"],
                  let source = LocaleCatalogVariable.Source(rawValue: rawSource),
                  case let .string(rawRole)? = object["role"],
                  let role = LocaleCatalogVariable.Role(rawValue: rawRole)
            else { return nil }
            variables.append(
                LocaleCatalogVariable(name: name, source: source, role: role)
            )
        }
        return variables
    }

    private static func variablesAreConsistent(_ variables: [LocaleCatalogVariable]) -> Bool {
        var roles: [String: LocaleCatalogVariable.Role] = [:]
        for variable in variables {
            let key = "\(variable.source.rawValue)\u{0}\(variable.name)"
            if let existing = roles[key], existing != variable.role {
                return false
            }
            roles[key] = variable.role
        }
        return true
    }
}
