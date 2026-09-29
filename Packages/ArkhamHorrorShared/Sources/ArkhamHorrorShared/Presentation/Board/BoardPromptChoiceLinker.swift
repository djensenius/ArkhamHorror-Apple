import Foundation

/// Board element identities that can mirror an active prompt choice.
enum BoardPromptElementID: Sendable, Equatable, Hashable {
    case playerCard(BoardPlayerCardID)
    case enemy(EnemyID)
    case treachery(TreacheryID)

    var focusID: SemanticFocusID {
        switch self {
        case let .playerCard(id): BoardFocusID.playerCard(id)
        case let .enemy(id): BoardFocusID.enemy(id)
        case let .treachery(id): BoardFocusID.threatTreachery(id)
        }
    }
}

struct BoardLinkedChoice: Sendable, Equatable {
    let choiceIndex: Int
    let title: String
    let isActionable: Bool
}

enum BoardPromptChoiceLinker {
    static func links(
        prompt: BasicChoicePromptPresentation?,
        projection: BoardProjection
    ) -> [BoardPromptElementID: [BoardLinkedChoice]] {
        guard let prompt else { return [:] }
        var result: [BoardPromptElementID: [BoardLinkedChoice]] = [:]
        for choice in prompt.choices {
            let linkedChoice = BoardLinkedChoice(
                choiceIndex: choice.index,
                title: prompt.displayTitle(for: choice, in: projection),
                isActionable: prompt.canSubmit && prompt.isChoiceActionable(choice, in: projection)
            )
            for elementID in elementIDs(for: choice, prompt: prompt) {
                result[elementID, default: []].append(linkedChoice)
            }
        }
        return result
    }

    private static func elementIDs(
        for choice: BasicChoice,
        prompt: BasicChoicePromptPresentation
    ) -> [BoardPromptElementID] {
        if let semanticPresentation = prompt.semanticPresentation {
            let descriptor = semanticPresentation.descriptor(forSourceIndex: choice.index)
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

    private static func uuidIdentifier<Tag: Sendable>(
        _ raw: String,
        as _: Identifier<Tag>.Type
    ) -> Identifier<Tag>? {
        Identifier(codingKey: AnyCodingKey(stringValue: raw))
    }
}
