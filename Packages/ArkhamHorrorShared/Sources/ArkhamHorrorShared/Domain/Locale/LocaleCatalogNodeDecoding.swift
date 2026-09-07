import Foundation

// swiftlint:disable file_length

/// Decoding for the closed render-AST node vocabulary.
///
/// Every branch here requires the node object's key set to be exactly what the schema
/// declares for that `type` (the schema is `additionalProperties: false` throughout), and an
/// unrecognised `type` fails the whole entry rather than being skipped. That is what makes
/// the AST closed: a future node kind this build does not implement can never be silently
/// dropped from the middle of an instruction.
///
/// Presentation-only members (`styles`, `style`, `styleVars`, `data`) are accepted where the
/// schema allows them and then discarded. The catalog states exactly when that is lossless:
/// `styles` "are hints only: a client may ignore any token without losing an instruction",
/// inline `style` is never a raw string and never an instruction, and `data` "is data, never
/// markup — a client that ignores `data` still renders the instruction". They are still
/// *validated* rather than ignored, so a malformed hint is a schema violation here exactly as
/// it is for the backend's own verifier.
extension LocaleCatalogNode {
    static func decodeList(_ value: JSONValue?, depth: Int) -> [LocaleCatalogNode]? {
        guard depth <= LocaleCatalogLimits.maxNodeDepth,
              case let .array(elements)? = value
        else { return nil }
        var nodes: [LocaleCatalogNode] = []
        nodes.reserveCapacity(elements.count)
        for element in elements {
            guard let node = decode(element, depth: depth) else { return nil }
            nodes.append(node)
        }

        return nodes
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func decode(_ value: JSONValue, depth: Int) -> LocaleCatalogNode? {
        guard depth <= LocaleCatalogLimits.maxNodeDepth,
              case let .object(object) = value,
              case let .string(type)? = object["type"]
        else { return nil }
        switch type {
        case "text": return decodeText(object)
        case "var": return decodeVariable(object)
        case "linked": return decodeLinked(object)
        case "break": return decodeVoid(object) ? .lineBreak : nil
        case "rule": return decodeVoid(object) ? .rule : nil
        case "paragraph", "group": return decodeBlock(
                object,
                isParagraph: type == "paragraph",
                depth: depth
            )
        case "heading": return decodeHeading(object, depth: depth)
        case "emphasis": return decodeEmphasis(object, depth: depth)
        case "list": return decodeListNode(object, depth: depth)
        case "image": return decodeImage(object)
        case "cardRef": return decodeCardReference(object, depth: depth)
        case "table": return decodeTable(object, depth: depth)
        default: return nil
        }
    }

    private static func decodeText(_ object: [String: JSONValue]) -> LocaleCatalogNode? {
        guard Set(object.keys) == ["type", "value"],
              case let .string(text)? = object["value"]
        else { return nil }
        return .text(text)
    }

    private static func decodeVariable(_ object: [String: JSONValue]) -> LocaleCatalogNode? {
        guard Set(object.keys) == ["type", "name", "source", "role"],
              case let .string(name)? = object["name"],
              LocaleCatalogGrammar.isVariableName(name),
              case let .string(rawSource)? = object["source"],
              let source = LocaleCatalogVariable.Source(rawValue: rawSource),
              case let .string(role)? = object["role"],
              role == "text" || role == "icon"
        else { return nil }
        return .variable(name: name, source: source, isIcon: role == "icon")
    }

    private static func decodeLinked(_ object: [String: JSONValue]) -> LocaleCatalogNode? {
        guard Set(object.keys) == ["type", "target", "modifier"],
              case let .object(target)? = object["target"],
              case let .string(kind)? = target["kind"]
        else { return nil }
        let modifier: LocaleCatalogLinkModifier?
        switch object["modifier"] {
        case let .string(raw)?:
            guard let parsed = LocaleCatalogLinkModifier(rawValue: raw) else { return nil }
            modifier = parsed
        case .null?:
            modifier = nil
        default:
            return nil
        }
        switch kind {
        case "static":
            guard Set(target.keys) == ["kind", "key"],
                  case let .string(key)? = target["key"],
                  LocaleCatalogGrammar.isMessageKey(key)
            else { return nil }
            return .linked(target: .staticKey(key), modifier: modifier)
        case "variable":
            guard Set(target.keys) == ["kind", "name", "source"],
                  case let .string(name)? = target["name"],
                  LocaleCatalogGrammar.isVariableName(name),
                  case let .string(rawSource)? = target["source"],
                  let source = LocaleCatalogVariable.Source(rawValue: rawSource)
            else { return nil }
            return .linked(target: .variable(name: name, source: source), modifier: modifier)
        default:
            return nil
        }
    }

    private static func decodeVoid(_ object: [String: JSONValue]) -> Bool {
        Set(object.keys) == ["type"]
    }

    private static func decodeBlock(
        _ object: [String: JSONValue], isParagraph: Bool, depth: Int
    ) -> LocaleCatalogNode? {
        let allowed: Set = ["type", "styles", "children", "style", "styleVars", "data"]
        guard Set(object.keys).isSubset(of: allowed),
              validatePresentation(object),
              object["styles"] != nil,
              let children = decodeList(object["children"], depth: depth + 1)
        else { return nil }
        return .block(isParagraph: isParagraph, children: children)
    }

    private static func decodeHeading(
        _ object: [String: JSONValue], depth: Int
    ) -> LocaleCatalogNode? {
        guard Set(object.keys).isSubset(of: [
            "type",
            "level",
            "styles",
            "children",
            "style",
            "styleVars",
        ]),
            validatePresentation(object),
            object["styles"] != nil,
            let level = LocaleCatalogManifest.nonNegativeInteger(object["level"]),
            (1 ... 6).contains(level),
            let children = decodeList(object["children"], depth: depth + 1)
        else { return nil }
        return .heading(level: level, children: children)
    }

    private static func decodeEmphasis(
        _ object: [String: JSONValue], depth: Int
    ) -> LocaleCatalogNode? {
        guard Set(object.keys) == ["type", "style", "children"],
              case let .string(rawStyle)? = object["style"],
              let style = LocaleCatalogEmphasis(rawValue: rawStyle),
              let children = decodeList(object["children"], depth: depth + 1)
        else { return nil }
        return .emphasis(style: style, children: children)
    }

    private static func decodeListNode(
        _ object: [String: JSONValue], depth: Int
    ) -> LocaleCatalogNode? {
        guard Set(object.keys).isSubset(of: [
            "type",
            "ordered",
            "styles",
            "items",
            "style",
            "styleVars",
            "implicit",
        ]),
            validatePresentation(object),
            object["styles"] != nil,
            case let .bool(ordered)? = object["ordered"],
            case let .array(rawItems)? = object["items"]
        else { return nil }
        if let rawImplicit = object["implicit"] {
            guard case .bool = rawImplicit else { return nil }
        }
        var items: [[LocaleCatalogNode]] = []
        items.reserveCapacity(rawItems.count)
        for rawItem in rawItems {
            guard case let .object(item) = rawItem,
                  Set(item.keys).isSubset(of: ["styles", "children", "style", "styleVars"]),
                  item["styles"] != nil,
                  validatePresentation(item),
                  let children = decodeList(item["children"], depth: depth + 1)
            else { return nil }
            items.append(children)
        }
        return .list(ordered: ordered, items: items)
    }

    private static func decodeImage(_ object: [String: JSONValue]) -> LocaleCatalogNode? {
        guard Set(object.keys).isSubset(of: [
            "type",
            "role",
            "assetPath",
            "styles",
            "alt",
            "style",
            "styleVars",
            "width",
            "align",
        ]),
            validatePresentation(object),
            object["styles"] != nil,
            case let .string(rawRole)? = object["role"],
            let role = LocaleCatalogAssetRole(rawValue: rawRole),
            case let .string(assetPath)? = object["assetPath"],
            LocaleCatalogGrammar.isAssetPath(assetPath)
        else { return nil }
        var alt: String?
        if let rawAlt = object["alt"] {
            guard case let .string(text) = rawAlt, text.count <= 240 else { return nil }
            alt = text
        }
        if let rawWidth = object["width"] {
            guard let width = LocaleCatalogManifest.nonNegativeInteger(rawWidth),
                  (1 ... 4096).contains(width)
            else { return nil }
        }
        if let rawAlign = object["align"] {
            guard case let .string(align) = rawAlign,
                  ["left", "right", "center", "justify"].contains(align)
            else { return nil }
        }
        return .image(role: role, assetPath: assetPath, alt: alt)
    }

    private static func decodeCardReference(
        _ object: [String: JSONValue], depth: Int
    ) -> LocaleCatalogNode? {
        guard Set(object.keys).isSubset(of: [
            "type",
            "code",
            "styles",
            "children",
            "style",
            "styleVars",
        ]),
            validatePresentation(object),
            object["styles"] != nil,
            case let .string(code)? = object["code"],
            LocaleCatalogGrammar.isCardRefCode(code),
            let children = decodeList(object["children"], depth: depth + 1)
        else { return nil }
        return .cardReference(code: code, children: children)
    }

    private static func decodeTable(
        _ object: [String: JSONValue], depth: Int
    ) -> LocaleCatalogNode? {
        guard Set(object.keys).isSubset(of: [
            "type",
            "styles",
            "head",
            "body",
            "style",
            "styleVars",
            "data",
        ]),
            validatePresentation(object),
            object["styles"] != nil,
            let head = decodeRows(object["head"], depth: depth + 1),
            let body = decodeRows(object["body"], depth: depth + 1)
        else { return nil }
        return .table(head: head, body: body)
    }

    private static func decodeRows(
        _ value: JSONValue?, depth: Int
    ) -> [LocaleCatalogTableRow]? {
        guard case let .array(rawRows)? = value, rawRows.count <= 64 else { return nil }
        var rows: [LocaleCatalogTableRow] = []
        rows.reserveCapacity(rawRows.count)
        for rawRow in rawRows {
            guard case let .object(row) = rawRow,
                  Set(row.keys).isSubset(of: ["styles", "cells", "style", "styleVars", "data"]),
                  row["styles"] != nil,
                  validatePresentation(row),
                  case let .array(rawCells)? = row["cells"], rawCells.count <= 32
            else { return nil }
            var cells: [LocaleCatalogTableCell] = []
            cells.reserveCapacity(rawCells.count)
            for rawCell in rawCells {
                guard case let .object(cell) = rawCell,
                      Set(cell.keys).isSubset(of: [
                          "header",
                          "styles",
                          "children",
                          "style",
                          "styleVars",
                          "data",
                      ]),
                      cell["styles"] != nil,
                      validatePresentation(cell),
                      case let .bool(isHeader)? = cell["header"],
                      let children = decodeList(cell["children"], depth: depth + 1)
                else { return nil }
                cells.append(LocaleCatalogTableCell(isHeader: isHeader, children: children))
            }
            rows.append(LocaleCatalogTableRow(cells: cells))
        }
        return rows
    }

    // MARK: - Presentation hints

    /// Validates every presentation-only member the node carries, then lets the caller drop
    /// it. A malformed hint is refused rather than ignored, so this client's acceptance
    /// surface is exactly the published schema's.
    private static func validatePresentation(_ object: [String: JSONValue]) -> Bool {
        if let styles = object["styles"], !isStyleTokenArray(styles) {
            return false
        }
        if let style = object["style"], !isStyleDeclarationArray(style) {
            return false
        }
        if let styleVars = object["styleVars"], !isStyleVariableArray(styleVars) {
            return false
        }
        if let data = object["data"], !isDataValueArray(data) {
            return false
        }
        return true
    }

    private static func isStyleTokenArray(_ value: JSONValue) -> Bool {
        guard case let .array(elements) = value else { return false }
        var seen: Set<String> = []
        for element in elements {
            guard case let .string(token) = element,
                  LocaleCatalogGrammar.isStyleToken(token),
                  seen.insert(token).inserted
            else { return false }
        }
        return true
    }

    private static func isStyleDeclarationArray(_ value: JSONValue) -> Bool {
        guard case let .array(elements) = value, elements.count <= 8 else { return false }
        return elements.allSatisfy { element in
            guard case let .object(declaration) = element,
                  case let .string(property)? = declaration["property"],
                  LocaleCatalogGrammar.isStyleProperty(property)
            else { return false }
            if Set(declaration.keys) == ["property", "value"] {
                guard case let .string(text)? = declaration["value"] else { return false }
                return LocaleCatalogGrammar.isStyleValue(text)
            }
            guard Set(declaration.keys) == ["property", "asset"],
                  case let .object(asset)? = declaration["asset"]
            else { return false }
            return isAssetReference(asset)
        }
    }

    private static func isAssetReference(_ asset: [String: JSONValue]) -> Bool {
        guard Set(asset.keys) == ["role", "assetPath"],
              case let .string(role)? = asset["role"],
              LocaleCatalogAssetRole(rawValue: role) != nil,
              case let .string(path)? = asset["assetPath"],
              LocaleCatalogGrammar.isAssetPath(path)
        else { return false }
        return true
    }

    private static func isStyleVariableArray(_ value: JSONValue) -> Bool {
        guard case let .array(elements) = value else { return false }
        return elements.allSatisfy { element in
            guard case let .object(variable) = element,
                  Set(variable.keys) == ["name", "source"],
                  case let .string(name)? = variable["name"],
                  LocaleCatalogGrammar.isVariableName(name),
                  case let .string(source)? = variable["source"],
                  LocaleCatalogVariable.Source(rawValue: source) != nil
            else { return false }
            return true
        }
    }

    private static func isDataValueArray(_ value: JSONValue) -> Bool {
        guard case let .array(elements) = value,
              (1 ... 4).contains(elements.count)
        else { return false }
        return elements.allSatisfy { element in
            guard case let .object(entry) = element,
                  case let .string(name)? = entry["name"],
                  ["count", "selected", "epilogue"].contains(name),
                  Set(entry.keys).isSubset(of: ["name", "text", "variable"])
            else { return false }
            let hasText = entry["text"] != nil
            let hasVariable = entry["variable"] != nil
            guard hasText != hasVariable else { return false }
            if case let .string(text)? = entry["text"] {
                return LocaleCatalogGrammar.isDataToken(text)
            }
            guard case let .object(variable)? = entry["variable"],
                  Set(variable.keys) == ["name", "source"],
                  case let .string(variableName)? = variable["name"],
                  LocaleCatalogGrammar.isVariableName(variableName),
                  case let .string(source)? = variable["source"],
                  LocaleCatalogVariable.Source(rawValue: source) != nil
            else { return false }
            return true
        }
    }

    /// Ensures every rendered placeholder and variable-targeted link has a declaration with
    /// the same source and compatible role. Presentation-only variables are intentionally
    /// excluded: they are validated syntactically and then discarded, never interpolated.
    static func referencesOnlyDeclaredVariables(
        _ nodes: [LocaleCatalogNode], declarations: [LocaleCatalogVariable]
    ) -> Bool {
        nodes.allSatisfy { referencesOnlyDeclaredVariables($0, declarations: declarations) }
    }

    private static func referencesOnlyDeclaredVariables(
        _ node: LocaleCatalogNode, declarations: [LocaleCatalogVariable]
    ) -> Bool {
        switch node {
        case .text, .lineBreak, .rule, .image:
            true
        case let .variable(name, source, isIcon):
            declarations.contains {
                $0.name == name && $0.source == source
                    && $0.role == (isIcon ? .icon : .text)
            }
        case let .linked(target, _):
            switch target {
            case .staticKey:
                true
            case let .variable(name, source):
                declarations.contains {
                    $0.name == name && $0.source == source && $0.role != .presentation
                }
            }
        case let .block(_, children), let .heading(_, children),
             let .emphasis(_, children), let .cardReference(_, children):
            referencesOnlyDeclaredVariables(children, declarations: declarations)
        case let .list(_, items):
            items.allSatisfy {
                referencesOnlyDeclaredVariables($0, declarations: declarations)
            }
        case let .table(head, body):
            (head + body).allSatisfy { row in
                row.cells.allSatisfy {
                    referencesOnlyDeclaredVariables($0.children, declarations: declarations)
                }
            }
        }
    }
}
