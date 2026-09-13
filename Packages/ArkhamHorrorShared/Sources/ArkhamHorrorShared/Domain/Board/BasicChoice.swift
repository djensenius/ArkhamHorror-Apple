import Foundation

struct BasicChoiceAbility: Sendable, Equatable, Hashable {
    let investigatorID: InvestigatorID
    let cardCode: CardCode
    let rawAbility: JSONValue
    let windows: [JSONValue]
    let before: [JSONValue]
    let messages: [JSONValue]
}

enum BasicChoiceHandCardPurpose: Sendable, Equatable, Hashable {
    case choose
    case commit
    case play
    case replace

    var actionTitle: String {
        switch self {
        case .choose: "Choose"
        case .commit: "Commit"
        case .play: "Play"
        case .replace: "Replace"
        }
    }
}

enum EnemyAttackAssignmentKind: Sendable, Equatable, Hashable {
    case damage
    case horror

    var actionTitle: String {
        switch self {
        case .damage: "Assign 1 damage"
        case .horror: "Assign 1 horror"
        }
    }

    var systemImage: String {
        switch self {
        case .damage: "heart.slash.fill"
        case .horror: "brain.head.profile"
        }
    }
}

struct EnemyAttackDamageAssignment: Sendable, Equatable, Hashable {
    let kind: EnemyAttackAssignmentKind
    let enemyID: EnemyID
    let investigatorID: InvestigatorID
    let messages: [JSONValue]
}

enum BasicChoiceContent: Sendable, Equatable, Hashable {
    case gainResource(investigatorID: InvestigatorID, messages: [JSONValue])
    case drawCard(investigatorID: InvestigatorID, messages: [JSONValue])
    case drawEncounterCard(investigatorID: InvestigatorID, messages: [JSONValue])
    case resolveEnemyAttack(
        enemyID: EnemyID, investigatorID: InvestigatorID, messages: [JSONValue]
    )
    case assignEnemyAttackDamage(EnemyAttackDamageAssignment)
    case endTurn(investigatorID: InvestigatorID, messages: [JSONValue])
    case investigate(BasicChoiceAbility)
    case fight(BasicChoiceAbility, enemyID: EnemyID)
    case evade(BasicChoiceAbility, enemyID: EnemyID)
    case continueReading(messages: [JSONValue])
    case finishMulligan(label: String, messages: [JSONValue])
    case chooseLocation(locationID: LocationID, messages: [JSONValue])
    case chooseHandCard(
        cardID: WireCardID, purpose: BasicChoiceHandCardPurpose, messages: [JSONValue]
    )
    case skipTriggers(investigatorID: InvestigatorID)
    case startSkillTest(investigatorID: InvestigatorID)
    case applySkillTestResults
    case unsupported(tag: String?)
}

struct BasicChoice: Sendable, Equatable, Hashable, Identifiable {
    let index: Int
    let rawValue: JSONValue
    let content: BasicChoiceContent

    var id: Int {
        index
    }

    var isSupported: Bool {
        if case .unsupported = content {
            false
        } else {
            true
        }
    }

    var title: String {
        switch content {
        case .gainResource: "Gain a resource"
        case .drawCard: "Draw a card"
        // Backend basic-choice-question.schema.json: encounterDeckDrawLabel.title.
        case .drawEncounterCard: "Draw encounter card"
        // Backend basic-choice-question.schema.json: chooseOneAtATimeEnemyAttackQuestion.title.
        case .resolveEnemyAttack: "Resolve enemy attack"
        case let .assignEnemyAttackDamage(assignment): assignment.kind.actionTitle
        case .endTurn: "End turn"
        case .investigate: "Investigate"
        case .fight: "Fight"
        case .evade: "Evade"
        case .continueReading: "Continue"
        case .finishMulligan: "Unavailable action"
        case .chooseLocation: "Choose starting location"
        case .chooseHandCard: "Unavailable card"
        case .skipTriggers: "Skip triggers"
        case .startSkillTest: "Start skill test"
        case .applySkillTestResults: "Apply results"
        case .unsupported: "Update required"
        }
    }

    var systemImage: String {
        switch content {
        case .gainResource: "circle.fill"
        case .drawCard, .drawEncounterCard: "rectangle.stack"
        case .resolveEnemyAttack: "shield.fill"
        case let .assignEnemyAttackDamage(assignment): assignment.kind.systemImage
        case .endTurn: "forward.end"
        case .investigate: "magnifyingglass"
        case .fight: "burst.fill"
        case .evade: "figure.run"
        case .continueReading: "arrow.right.circle.fill"
        case .finishMulligan: "checkmark.circle.fill"
        case .chooseLocation: "mappin.and.ellipse"
        case .chooseHandCard: "rectangle.portrait"
        case .skipTriggers: "forward.end.alt"
        case .startSkillTest: "play.circle.fill"
        case .applySkillTestResults: "checkmark.seal.fill"
        case .unsupported: "exclamationmark.triangle"
        }
    }

    var ability: BasicChoiceAbility? {
        switch content {
        case let .investigate(ability), let .fight(ability, _), let .evade(ability, _):
            ability
        default:
            nil
        }
    }

    var locationID: LocationID? {
        guard case let .chooseLocation(locationID, _) = content else { return nil }
        return locationID
    }

    var cardID: WireCardID? {
        guard case let .chooseHandCard(cardID, _, _) = content else { return nil }
        return cardID
    }

    var localizationKey: String? {
        guard case let .finishMulligan(label, _) = content,
              label.first == "$"
        else { return nil }
        return String(label.dropFirst())
    }
}
