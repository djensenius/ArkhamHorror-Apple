import Foundation

/// Board element identities that can mirror an active prompt choice.
enum BoardPromptElementID: Sendable, Equatable, Hashable {
    case playerCard(BoardPlayerCardID)
    case enemy(EnemyID)
    case treachery(TreacheryID)
    case chaosToken(ChaosTokenID)

    var rawFocusComponent: String {
        switch self {
        case let .playerCard(cardID): "playerCard.\(cardID.rawFocusComponent)"
        case let .enemy(enemyID): "enemy.\(enemyID.codingKey.stringValue)"
        case let .treachery(treacheryID): "treachery.\(treacheryID.codingKey.stringValue)"
        case let .chaosToken(tokenID): "chaosToken.\(tokenID.codingKey.stringValue)"
        }
    }
}

extension BoardPlayerCardID {
    var rawFocusComponent: String {
        switch self {
        case let .card(id): "card.\(id.codingKey.stringValue)"
        case let .asset(id): "asset.\(id.codingKey.stringValue)"
        case let .event(id): "event.\(id.codingKey.stringValue)"
        case let .skill(id): "skill.\(id.codingKey.stringValue)"
        }
    }
}

struct BoardLinkedChoice: Sendable, Equatable {
    let choiceIndex: Int
    let title: String
    let isActionable: Bool
    /// Inline nodes for `title`, set only when the title carries a `[^N]` footnote marker
    /// that `title` flattens to run-together digits (TASK-1.22.12); `nil` otherwise.
    let displayNodes: [StoryNode]?
    /// The VoiceOver form of `title` ("… footnote N"), set together with `displayNodes`.
    let accessibilityTitle: String?

    init(
        choiceIndex: Int,
        title: String,
        isActionable: Bool,
        displayNodes: [StoryNode]? = nil,
        accessibilityTitle: String? = nil
    ) {
        self.choiceIndex = choiceIndex
        self.title = title
        self.isActionable = isActionable
        self.displayNodes = displayNodes
        self.accessibilityTitle = accessibilityTitle
    }

    /// What VoiceOver reads for this choice.
    var spokenTitle: String {
        accessibilityTitle ?? title
    }

    /// The title for native `Menu`/`Button(String)` labels, which cannot render a marker
    /// view: footnote markers become Unicode superscript digits. Falls back to `title`
    /// when the nodes' plain text does not match it (for example spoken icon names).
    var menuTitle: String {
        guard let displayNodes,
              displayNodes.map(\.plainText).joined() == title,
              let raised = StoryFootnoteSuperscript.title(for: displayNodes)
        else { return title }
        return raised
    }
}

/// Unicode superscript digits for `[^N]` footnote markers on plain-string surfaces.
enum StoryFootnoteSuperscript {
    private static let digits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]

    /// The ASCII digits `number` as superscript digits (`12` -> `¹²`).
    static func superscript(_ number: String) -> String {
        String(number.map { digits[$0] ?? $0 })
    }

    /// The plain text of `nodes` with every footnote marker raised to superscript digits,
    /// or `nil` when the nodes carry no footnote marker.
    static func title(for nodes: [StoryNode]) -> String? {
        let raised = nodes.map { $0.flattened(footnote: superscript) }.joined()
        return raised == nodes.map(\.plainText).joined() ? nil : raised
    }
}

struct BoardLinkedChoiceMenuRequest: Sendable, Equatable {
    let focusID: SemanticFocusID
    let choices: [BoardLinkedChoice]
}

enum BoardPromptChoiceLinker {
    static func links(
        prompt: BasicChoicePromptPresentation?,
        projection: BoardProjection
    ) -> [BoardPromptElementID: [BoardLinkedChoice]] {
        guard let prompt else { return [:] }
        var result: [BoardPromptElementID: [BoardLinkedChoice]] = [:]
        var firstMatchedChaosTokenElements: Set<BoardPromptElementID> = []
        for choice in prompt.choices {
            let isActionable = prompt.canSubmit
                && prompt.isChoiceActionable(choice, in: projection)
            for elementID in elementIDs(for: choice, prompt: prompt, projection: projection) {
                if case .chaosToken = elementID {
                    guard firstMatchedChaosTokenElements.insert(elementID).inserted else {
                        continue
                    }
                }
                result[elementID, default: []].append(linkedChoice(
                    for: choice, isActionable: isActionable, prompt: prompt, projection: projection
                ))
            }
        }
        return result
    }

    private static func elementIDs(
        for choice: BasicChoice,
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) -> [BoardPromptElementID] {
        if let semanticPresentation = prompt.semanticPresentation {
            let descriptor = semanticPresentation.descriptor(forSourceIndex: choice.index)
            let chaosTokenIDs = actionableChaosTokenElementIDs(
                for: descriptor,
                projection: projection
            )
            if !chaosTokenIDs.isEmpty {
                return chaosTokenIDs
            }
            if let semantic = semanticElementID(for: descriptor?.entity) {
                return [semantic]
            }
        }
        switch choice.content {
        case let .chooseHandCard(cardID, _, _):
            return [.playerCard(.card(cardID))]
        case let .fight(_, enemyID), let .evade(_, enemyID), let .engage(_, enemyID):
            return [.enemy(enemyID)]
        case let .resolveEnemyAttack(enemyID, _, _):
            return [.enemy(enemyID)]
        case let .assignEnemyAttackDamage(assignment):
            return [.enemy(assignment.enemyID)]
        case let .coverUpReaction(reaction):
            return [.treachery(reaction.treacheryID)]
        case let .resolveForcedAbility(forced):
            return [.treachery(forced.treacheryID)]
        default:
            return []
        }
    }

    private static func linkedChoice(
        for choice: BasicChoice,
        isActionable: Bool,
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) -> BoardLinkedChoice {
        let label = prompt.resolvedChoiceLabel(for: choice, in: projection)
        // Only a footnoted title carries nodes and a spoken form; others stay as before.
        guard let nodes = label.titleNodes,
              StoryFootnoteSuperscript.title(for: nodes) != nil
        else {
            return BoardLinkedChoice(
                choiceIndex: choice.index, title: label.title, isActionable: isActionable
            )
        }
        return BoardLinkedChoice(
            choiceIndex: choice.index,
            title: label.title,
            isActionable: isActionable,
            displayNodes: nodes,
            accessibilityTitle: label.accessibilityLabel
        )
    }

    private static func semanticElementID(
        for entity: QuestionPresentation.Entity?
    ) -> BoardPromptElementID? {
        guard let entity else { return nil }
        switch entity.kind {
        case .card:
            return uuidIdentifier(entity.id, as: WireCardID.self).map { .playerCard(.card($0)) }
        case .enemy:
            return uuidIdentifier(entity.id, as: EnemyID.self).map { .enemy($0) }
        case .treachery:
            return uuidIdentifier(entity.id, as: TreacheryID.self).map { .treachery($0) }
        case .asset:
            return uuidIdentifier(entity.id, as: AssetID.self).map { .playerCard(.asset($0)) }
        case .event:
            return uuidIdentifier(entity.id, as: EventID.self).map { .playerCard(.event($0)) }
        case .skill:
            return uuidIdentifier(entity.id, as: SkillID.self).map { .playerCard(.skill($0)) }
        default:
            return nil
        }
    }

    static func chaosTokenElementIDs(
        for target: JSONValue?,
        projection: BoardProjection
    ) -> [BoardPromptElementID] {
        guard case let .object(object)? = target,
              case let .string(tag)? = object["tag"]
        else { return [] }
        switch tag {
        case "ChaosTokenTarget":
            guard case let .object(contents)? = object["contents"],
                  let rawID = chaosTokenIDText(in: contents),
                  let tokenID = uuidIdentifier(rawID, as: ChaosTokenID.self),
                  projection.targetableChaosTokens.contains(where: { $0.id == tokenID })
            else { return [] }
            return [.chaosToken(tokenID)]
        case "ChaosTokenFaceTarget":
            guard case let .string(rawFace)? = object["contents"] else { return [] }
            let face = ChaosTokenFace(rawFace)
            return projection.targetableChaosTokens
                .filter { $0.face == face }
                .map { .chaosToken($0.id) }
        default:
            return []
        }
    }

    private static func actionableChaosTokenElementIDs(
        for descriptor: QuestionPresentation.Choice?,
        projection: BoardProjection
    ) -> [BoardPromptElementID] {
        guard let descriptor else { return [] }
        switch descriptor.kind {
        case .chaosTokenGroupChoice:
            return chaosTokenGroupElementIDs(
                for: descriptor.step,
                projection: projection
            )
        default:
            guard descriptor.uiTag == "TargetLabel" else { return [] }
            return chaosTokenElementIDs(for: descriptor.target, projection: projection)
        }
    }

    private static func chaosTokenGroupElementIDs(
        for step: JSONValue?,
        projection: BoardProjection
    ) -> [BoardPromptElementID] {
        guard case let .object(object)? = step,
              case let .array(groups)? = object["tokenGroups"]
        else { return [] }
        let groupedTokenIDs = Set(groups.flatMap { group -> [ChaosTokenID] in
            guard case let .array(tokens) = group else { return [] }
            return tokens.compactMap { token in
                guard case let .object(contents) = token,
                      let rawID = chaosTokenIDText(in: contents)
                else { return nil }
                return uuidIdentifier(rawID, as: ChaosTokenID.self)
            }
        })
        return projection.targetableChaosTokens
            .filter { groupedTokenIDs.contains($0.id) }
            .map { .chaosToken($0.id) }
    }

    private static func chaosTokenIDText(in contents: [String: JSONValue]) -> String? {
        if case let .string(rawID)? = contents["chaosTokenId"] {
            return rawID
        }
        if case let .string(rawID)? = contents["id"] {
            return rawID
        }
        return nil
    }

    private static func uuidIdentifier<Tag: Sendable>(
        _ raw: String,
        as _: Identifier<Tag>.Type
    ) -> Identifier<Tag>? {
        Identifier(codingKey: AnyCodingKey(stringValue: raw))
    }
}
