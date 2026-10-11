import Foundation

/// Shared inline icon parsing for server-provided button labels that still contain the
/// web's literal `{iconName}` placeholders. Catalog-rendered story text already arrives as
/// `StoryNode.semanticIcon`; this parser exists only for non-catalog label strings.
enum StoryIconInlineParser {
    static func nodes(for text: String) -> [StoryNode]? {
        var nodes: [StoryNode] = []
        var cursor = text.startIndex
        var foundIcon = false

        while cursor < text.endIndex {
            guard let open = text[cursor...].firstIndex(of: "{") else {
                appendText(String(text[cursor...]), to: &nodes)
                break
            }
            appendText(String(text[cursor ..< open]), to: &nodes)
            guard let close = text[text.index(after: open)...].firstIndex(of: "}") else {
                appendText(String(text[open...]), to: &nodes)
                break
            }

            let name = String(text[text.index(after: open) ..< close])
            if let icon = StoryIcon.iconVariableValue(name) {
                nodes.append(.semanticIcon(icon))
                foundIcon = true
            } else {
                appendText(String(text[open ... close]), to: &nodes)
            }
            cursor = text.index(after: close)
        }

        return foundIcon ? nodes : nil
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
