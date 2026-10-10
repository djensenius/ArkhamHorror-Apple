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
                let linkedChoice = BoardLinkedChoice(
                    choiceIndex: choice.index,
                    title: title(
                        for: elementID, choice: choice, prompt: prompt, projection: projection
                    ),
                    isActionable: isActionable
                )
                result[elementID, default: []].append(linkedChoice)
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

    private static func title(
        for _: BoardPromptElementID,
        choice: BasicChoice,
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) -> String {
        prompt.displayTitle(for: choice, in: projection)
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
                .filter { isActionableChaosTokenElement($0, projection: projection) }
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
            .filter { !$0.cancelled && groupedTokenIDs.contains($0.id) }
            .map { .chaosToken($0.id) }
    }

    private static func isActionableChaosTokenElement(
        _ elementID: BoardPromptElementID,
        projection: BoardProjection
    ) -> Bool {
        guard case let .chaosToken(tokenID) = elementID,
              let token = projection.targetableChaosTokens.first(where: { $0.id == tokenID })
        else { return false }
        return !token.cancelled
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
