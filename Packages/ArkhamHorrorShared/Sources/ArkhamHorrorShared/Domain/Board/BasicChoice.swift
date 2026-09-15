import Foundation

struct BasicChoiceAbility: Sendable, Equatable, Hashable {
    let investigatorID: InvestigatorID
    let cardCode: CardCode
    let rawAbility: JSONValue
    let windows: [JSONValue]
    let before: [JSONValue]
    let messages: [JSONValue]
}

struct ForcedAbilityChoice: Sendable, Equatable, Hashable {
    let ability: BasicChoiceAbility
    let treacheryID: TreacheryID
}

struct RolandDefeatReactionChoice: Sendable, Equatable, Hashable {
    let ability: BasicChoiceAbility
    let defeatedEnemyID: EnemyID
}

struct CoverUpReactionChoice: Sendable, Equatable, Hashable {
    let ability: BasicChoiceAbility
    let treacheryID: TreacheryID
    let locationID: LocationID
    let skillTestID: SkillTestID
}

struct AgendaConsequenceChoice: Sendable, Equatable, Hashable {
    enum Kind: Sendable, Equatable, Hashable {
        case takeHorror
        case randomDiscard

        var systemImage: String {
            switch self {
            case .takeHorror: "brain.head.profile"
            case .randomDiscard: "rectangle.stack.badge.minus"
            }
        }
    }

    let kind: Kind
    let label: String
    let agendaID: AgendaID
    let investigatorID: InvestigatorID?
    let messages: [JSONValue]
}

struct AgendaHorrorAssignment: Sendable, Equatable, Hashable {
    let agendaID: AgendaID
    let investigatorID: InvestigatorID
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
    case engage(BasicChoiceAbility, enemyID: EnemyID)
    case rolandDefeatReaction(RolandDefeatReactionChoice)
    case coverUpReaction(CoverUpReactionChoice)
    case resolveForcedAbility(ForcedAbilityChoice)
    case advanceAgenda(agendaID: AgendaID, messages: [JSONValue])
    case chooseAgendaConsequence(AgendaConsequenceChoice)
    case assignAgendaHorror(AgendaHorrorAssignment)
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
        case .engage: "Engage"
        case .rolandDefeatReaction: "Discover 1 clue"
        case .coverUpReaction: "Remove 1 clue from Cover Up"
        case .resolveForcedAbility: "Resolve forced ability"
        case .advanceAgenda: "Advance agenda"
        case .chooseAgendaConsequence: "Unavailable action"
        case .assignAgendaHorror: "Assign 2 horror"
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
        case .engage: "person.2.fill"
        case .rolandDefeatReaction: "magnifyingglass.circle.fill"
        case .coverUpReaction: "minus.circle.fill"
        case .resolveForcedAbility: "exclamationmark.triangle.fill"
        case .advanceAgenda: "arrow.up.circle.fill"
        case let .chooseAgendaConsequence(choice): choice.kind.systemImage
        case .assignAgendaHorror: "brain.head.profile"
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
        case let .investigate(ability), let .fight(ability, _), let .evade(ability, _),
             let .engage(ability, _):
            ability
        case let .rolandDefeatReaction(choice):
            choice.ability
        case let .coverUpReaction(choice):
            choice.ability
        case let .resolveForcedAbility(choice):
            choice.ability
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
        let label: String
        switch content {
        case let .finishMulligan(value, _):
            label = value
        case let .chooseAgendaConsequence(choice):
            label = choice.label
        default:
            return nil
        }
        guard label.first == "$" else { return nil }
        return String(label.dropFirst())
    }
}
