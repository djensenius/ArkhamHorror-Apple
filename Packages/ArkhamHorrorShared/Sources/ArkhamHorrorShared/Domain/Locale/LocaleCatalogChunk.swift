// swiftlint:disable file_length
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
        /// Production `replaceIcons()` renders this node's name as an icon glyph; the catalog
        /// preserves the placeholder instead of rendering it.
        case icon
        /// The backend-supplied variable value is a proven icon name. Clients that do not
        /// implement that icon vocabulary must treat only this entry as unavailable.
        case iconVariable
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
    /// A typed placeholder. `role` is `text`, `icon`, or `iconVariable` here — a
    /// `presentation` variable never reaches a text position, only an attribute.
    case variable(
        name: String,
        source: LocaleCatalogVariable.Source,
        role: LocaleCatalogVariable.Role
    )
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
            guard LocaleCatalogGrammar.isMessageKey(key) else {
                return .failure(.malformedChunk)
            }
            switch LocaleCatalogEntry.decode(rawEntry) {
            case let .success(entry):
                entries[key] = entry
            case .unsupportedAdditiveField:
                entries[key] = .unsupported(reason: "client-unsupported-additive-field")
            case .malformed:
                return .failure(.malformedChunk)
            }
        }
        let unsupportedKeys = entries.values.reduce(into: 0) { count, entry in
            if entry.countsAsManifestUnsupported {
                count += 1
            }
        }
        guard entries.count == expectedKeys,
              unsupportedKeys == expectedUnsupportedKeys
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
    var countsAsManifestUnsupported: Bool {
        guard case let .unsupported(reason) = self else { return false }
        return Self.unsupportedReasons.contains(reason)
    }

    enum DecodeResult {
        case success(LocaleCatalogEntry)
        case unsupportedAdditiveField
        case malformed
    }

    static func decode(_ value: JSONValue) -> DecodeResult {
        guard case let .object(object) = value, case let .string(form)? = object["form"] else {
            return .malformed
        }
        switch form {
        case "message":
            return decodeMessage(object)
        case "plural":
            return decodePlural(object)
        case "unsupported":
            guard Set(object.keys) == ["form", "reason", "detail"],
                  case let .string(reason)? = object["reason"],
                  Self.unsupportedReasons.contains(reason),
                  case let .string(detail)? = object["detail"],
                  detail.count <= 120
            else { return .malformed }
            return .success(.unsupported(reason: reason))
        default:
            return .malformed
        }
    }

    private static func decodeMessage(_ object: [String: JSONValue]) -> DecodeResult {
        guard Set(object.keys).isSubset(of: ["form", "nodes", "variables", "linkedVariables"]),
              object["nodes"] != nil, object["variables"] != nil
        else { return .malformed }
        guard let declarations = decodeDeclarations(
            variables: object["variables"], linkedVariables: object["linkedVariables"]
        ) else { return .malformed }
        let nodeResult = decodeNodesForEntry(
            object["nodes"],
            unknownRoleDeclarations: declarations.unknownRoleVariables
        )
        guard case let .success(nodes, nodeHasAdditiveRole) = nodeResult else { return .malformed }
        guard LocaleCatalogNode.referencesOnlyDeclaredVariables(
            nodes,
            declarations: declarations.variables,
            unknownRoleDeclarations: declarations.unknownRoleVariables
        ) else { return .malformed }
        guard !declarations.hasAdditiveRole, !nodeHasAdditiveRole else {
            return .unsupportedAdditiveField
        }
        return .success(.message(nodes: nodes, variables: declarations.variables))
    }

    private static func decodePlural(_ object: [String: JSONValue]) -> DecodeResult {
        guard Set(object.keys).isSubset(of: ["form", "cases", "variables", "linkedVariables"]),
              object["cases"] != nil, object["variables"] != nil,
              case let .array(rawCases)? = object["cases"], !rawCases.isEmpty
        else { return .malformed }
        guard let declarations = decodeDeclarations(
            variables: object["variables"], linkedVariables: object["linkedVariables"]
        ) else { return .malformed }
        var cases: [[LocaleCatalogNode]] = []
        var hasAdditiveRole = declarations.hasAdditiveRole
        cases.reserveCapacity(rawCases.count)
        for rawCase in rawCases {
            let nodeResult = decodeNodesForEntry(
                rawCase,
                unknownRoleDeclarations: declarations.unknownRoleVariables
            )
            guard case let .success(nodes, nodeHasAdditiveRole) = nodeResult else {
                return .malformed
            }
            guard LocaleCatalogNode.referencesOnlyDeclaredVariables(
                nodes,
                declarations: declarations.variables,
                unknownRoleDeclarations: declarations.unknownRoleVariables
            ) else { return .malformed }
            hasAdditiveRole = hasAdditiveRole || nodeHasAdditiveRole
            cases.append(nodes)
        }
        guard !hasAdditiveRole else { return .unsupportedAdditiveField }
        return .success(.plural(cases: cases, variables: declarations.variables))
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

    struct UnknownVariableRoleDeclaration: Sendable, Equatable, Hashable {
        let name: String
        let source: LocaleCatalogVariable.Source
        let rawRole: String
    }

    private struct Declarations {
        let variables: [LocaleCatalogVariable]
        let unknownRoleVariables: [UnknownVariableRoleDeclaration]

        var hasAdditiveRole: Bool {
            !unknownRoleVariables.isEmpty
        }
    }

    private enum NodeListDecodeResult {
        case success(nodes: [LocaleCatalogNode], hasAdditiveRole: Bool)
        case malformed
    }

    private enum VariableDecodeResult {
        case success(
            variables: [LocaleCatalogVariable],
            unknownRoleVariables: [UnknownVariableRoleDeclaration]
        )
        case malformed
    }

    private static func decodeDeclarations(
        variables rawVariables: JSONValue?, linkedVariables rawLinkedVariables: JSONValue?
    ) -> Declarations? {
        let variableResult = decodeVariables(rawVariables)
        let linkedResult = decodeOptionalVariables(rawLinkedVariables)
        guard case let .success(variables, unknownVariables) = variableResult,
              case let .success(linked, unknownLinked) = linkedResult,
              variablesAreConsistent(
                  variables + linked,
                  unknownRoleVariables: unknownVariables + unknownLinked
              )
        else { return nil }
        return Declarations(
            variables: variables + linked,
            unknownRoleVariables: unknownVariables + unknownLinked
        )
    }

    private static func decodeNodesForEntry(
        _ value: JSONValue?,
        unknownRoleDeclarations: [UnknownVariableRoleDeclaration]
    ) -> NodeListDecodeResult {
        if let nodes = LocaleCatalogNode.decodeList(value, depth: 0) {
            return .success(nodes: nodes, hasAdditiveRole: false)
        }
        guard let transformed = replacingAdditiveVariableRoleNodes(
            in: value,
            unknownRoleDeclarations: unknownRoleDeclarations
        ),
            let nodes = LocaleCatalogNode.decodeList(transformed, depth: 0)
        else { return .malformed }
        return .success(nodes: nodes, hasAdditiveRole: true)
    }

    private static func replacingAdditiveVariableRoleNodes(
        in value: JSONValue?,
        unknownRoleDeclarations: [UnknownVariableRoleDeclaration]
    ) -> JSONValue? {
        guard let value else { return nil }
        var foundAdditiveRole = false
        guard let transformed = replacingAdditiveVariableRoleNodes(
            in: value,
            unknownRoleDeclarations: unknownRoleDeclarations,
            foundAdditiveRole: &foundAdditiveRole
        ), foundAdditiveRole
        else { return nil }
        return transformed
    }

    private static func replacingAdditiveVariableRoleNodes(
        in value: JSONValue,
        unknownRoleDeclarations: [UnknownVariableRoleDeclaration],
        foundAdditiveRole: inout Bool
    ) -> JSONValue? {
        switch value {
        case let .array(elements):
            let transformed = elements.compactMap {
                replacingAdditiveVariableRoleNodes(
                    in: $0,
                    unknownRoleDeclarations: unknownRoleDeclarations,
                    foundAdditiveRole: &foundAdditiveRole
                )
            }
            return transformed.count == elements.count ? .array(transformed) : nil
        case let .object(object):
            if let replacement = additiveVariableRoleReplacement(
                for: object,
                unknownRoleDeclarations: unknownRoleDeclarations
            ) {
                foundAdditiveRole = true
                return replacement
            }
            var transformed: [String: JSONValue] = [:]
            transformed.reserveCapacity(object.count)
            for (key, child) in object {
                guard let replaced = replacingAdditiveVariableRoleNodes(
                    in: child,
                    unknownRoleDeclarations: unknownRoleDeclarations,
                    foundAdditiveRole: &foundAdditiveRole
                ) else { return nil }
                transformed[key] = replaced
            }
            return .object(transformed)
        case .string, .number, .bool, .null:
            return value
        }
    }

    private static func additiveVariableRoleReplacement(
        for object: [String: JSONValue],
        unknownRoleDeclarations: [UnknownVariableRoleDeclaration]
    ) -> JSONValue? {
        guard object["type"] == .string("var") else { return nil }
        guard Set(object.keys) == ["type", "name", "source", "role"],
              case let .string(name)? = object["name"],
              LocaleCatalogGrammar.isVariableName(name),
              case let .string(rawSource)? = object["source"],
              let source = LocaleCatalogVariable.Source(rawValue: rawSource),
              case let .string(rawRole)? = object["role"],
              LocaleCatalogGrammar.isVariableRole(rawRole),
              rawRole != LocaleCatalogVariable.Role.presentation.rawValue,
              LocaleCatalogVariable.Role(rawValue: rawRole) == nil
        else { return nil }
        guard unknownRoleDeclarations.contains(where: {
            $0.name == name && $0.source == source && $0.rawRole == rawRole
        }) else { return nil }
        return .object(["type": .string("text"), "value": .string("")])
    }

    private static func decodeOptionalVariables(_ value: JSONValue?) -> VariableDecodeResult {
        guard let value else {
            return .success(variables: [], unknownRoleVariables: [])
        }
        return decodeVariables(value)
    }

    private static func decodeVariables(_ value: JSONValue?) -> VariableDecodeResult {
        guard case let .array(elements)? = value,
              elements.count <= LocaleCatalogLimits.maxVariablesPerEntry
        else { return .malformed }
        var variables: [LocaleCatalogVariable] = []
        var unknownRoleVariables: [UnknownVariableRoleDeclaration] = []
        variables.reserveCapacity(elements.count)
        for element in elements {
            guard case let .object(object) = element,
                  Set(object.keys) == ["name", "source", "role"],
                  case let .string(name)? = object["name"],
                  LocaleCatalogGrammar.isVariableName(name),
                  case let .string(rawSource)? = object["source"],
                  let source = LocaleCatalogVariable.Source(rawValue: rawSource),
                  case let .string(rawRole)? = object["role"],
                  LocaleCatalogGrammar.isVariableRole(rawRole)
            else { return .malformed }
            guard let role = LocaleCatalogVariable.Role(rawValue: rawRole) else {
                unknownRoleVariables.append(UnknownVariableRoleDeclaration(
                    name: name,
                    source: source,
                    rawRole: rawRole
                ))
                continue
            }
            variables.append(
                LocaleCatalogVariable(name: name, source: source, role: role)
            )
        }
        return .success(variables: variables, unknownRoleVariables: unknownRoleVariables)
    }

    private static func variablesAreConsistent(
        _ variables: [LocaleCatalogVariable],
        unknownRoleVariables: [UnknownVariableRoleDeclaration]
    ) -> Bool {
        var roles: [String: String] = [:]
        for variable in variables {
            let key = "\(variable.source.rawValue)\u{0}\(variable.name)"
            if let existing = roles[key], existing != variable.role.rawValue {
                return false
            }
            roles[key] = variable.role.rawValue
        }
        for variable in unknownRoleVariables {
            let key = "\(variable.source.rawValue)\u{0}\(variable.name)"
            if let existing = roles[key], existing != variable.rawRole {
                return false
            }
            roles[key] = variable.rawRole
        }
        return true
    }
}
