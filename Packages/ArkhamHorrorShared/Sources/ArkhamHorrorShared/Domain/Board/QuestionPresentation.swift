import Foundation

/// Render-only semantic metadata bound to one authoritative raw question.
///
/// The backend remains the sole authority for legality, costs, mutable state, and answer
/// execution. A bound presentation only describes existing raw choice indices; callers still
/// submit ``BasicChoiceAnswer`` with the original source index and question version.
struct QuestionPresentation: Sendable, Equatable, Hashable {
    static let supportedProtocolVersion = 1

    let protocolVersion: Int
    let questionVersion: Int
    let questionKind: Kind
    let choiceCount: Int
    let choices: [Choice]
}

extension QuestionPresentation {
    enum Kind: String, Sendable, Equatable, Hashable, Codable {
        case chooseN
        case chooseOne
        case chooseOneAtATime
        case chooseSome
        case chooseUpToN
        case playerWindowChooseOne
        case read
        case unsupported
        case windowChooseOne
    }

    enum ChoiceKind: String, Sendable, Equatable, Hashable, Codable {
        case advanceAct
        case advanceAgenda
        case applySkillTestResults
        case assignDamage
        case assignHorror
        case chooseTarget
        case drawCard
        case drawEncounterCard
        case endTurn
        case engage
        case evade
        case fight
        case gainResource
        case investigate
        case localizedLabel
        case move
        case resolveForcedAbility
        case skipTriggers
        case startSkillTest
        case useAbility
    }

    struct Choice: Sendable, Equatable, Hashable {
        let sourceIndex: Int
        let kind: ChoiceKind
        let actorID: String?
        let entity: Entity?
        let label: Label?
        let ability: Ability?
        let cost: Cost?
    }

    enum EntityKind: String, Sendable, Equatable, Hashable, Codable {
        case act
        case agenda
        case asset
        case card
        case cardCode
        case effect
        case enemy
        case event
        case investigator
        case location
        case player
        case scenario
        case skill
        case story
        case treachery
    }

    struct Entity: Sendable, Equatable, Hashable {
        let kind: EntityKind
        let id: String
    }

    struct GovernedSource: Sendable, Equatable, Hashable {
        let entity: Entity
        let cardCode: String
    }

    enum LabelKind: String, Sendable, Equatable, Hashable, Codable {
        case embeddedI18n
    }

    struct Label: Sendable, Equatable, Hashable {
        let kind: LabelKind
        let text: String
    }

    enum AbilityType: String, Sendable, Equatable, Hashable, Codable {
        case action
        case delayed
        case effect
        case fast
        case forced
        case objective
        case other
        case reaction
    }

    enum Action: String, Sendable, Equatable, Hashable, Codable {
        case activate
        case circle
        case draw
        case engage
        case evade
        case explore
        case fight
        case investigate
        case move
        case parley
        case play
        case resign
        case resource
    }

    struct Ability: Sendable, Equatable, Hashable {
        let cardCode: String
        let index: Int
        let type: AbilityType
        let actions: [Action]
        let canBeCancelled: Bool
    }

    indirect enum Cost: Sendable, Equatable, Hashable {
        case free
        case action(Int)
        case resource(Int)
        case clue(Amount)
        case groupClue(amount: Amount, scope: Scope)
        case groupResource(amount: Amount, scope: Scope)
        case all([Cost])
        case choice([Cost])
        case other
    }

    enum Amount: Sendable, Equatable, Hashable {
        case fixed(Int)
        case perPlayer(Int)
        case fixedPlusPerPlayer(fixed: Int, perPlayer: Int)
        case byPlayerCount([Int])
        case variable
        case star
        case unknown
    }

    enum Scope: Sendable, Equatable, Hashable {
        case anywhere
        case sameLocation
        case location(String)
        case other
    }
}

/// A presentation after its version, kind, and count have been matched to the raw question.
struct BoundQuestionPresentation: Sendable, Equatable, Hashable {
    let presentation: QuestionPresentation
    let rawChoices: [JSONValue]
    let governedSource: QuestionPresentation.GovernedSource?

    func descriptor(forSourceIndex sourceIndex: Int) -> QuestionPresentation.Choice? {
        presentation.choices.first { $0.sourceIndex == sourceIndex }
    }

    func rawChoice(at sourceIndex: Int) -> JSONValue? {
        guard rawChoices.indices.contains(sourceIndex) else { return nil }
        return rawChoices[sourceIndex]
    }
}

enum QuestionPresentationBindingError: Error, Sendable, Equatable {
    case invalidRawQuestion(String)
    case questionVersion(expected: Int, actual: Int)
    case questionKind(expected: QuestionPresentation.Kind, actual: QuestionPresentation.Kind)
    case choiceCount(expected: Int, actual: Int)
    case rawChoiceMismatch(sourceIndex: Int)
    case governedChoicesMismatch
}

extension QuestionPresentation {
    func bind(
        to rawQuestion: JSONValue,
        expectedQuestionVersion: Int
    ) throws -> BoundQuestionPresentation {
        guard questionVersion == expectedQuestionVersion else {
            throw QuestionPresentationBindingError.questionVersion(
                expected: expectedQuestionVersion,
                actual: questionVersion
            )
        }
        let rawShape = try QuestionPresentationRawQuestionDeriver.derive(rawQuestion)
        guard questionKind == rawShape.kind else {
            throw QuestionPresentationBindingError.questionKind(
                expected: rawShape.kind,
                actual: questionKind
            )
        }
        guard choiceCount == rawShape.choices.count else {
            throw QuestionPresentationBindingError.choiceCount(
                expected: rawShape.choices.count,
                actual: choiceCount
            )
        }
        let governedSource = try rawShape.validateGovernedChoices(for: self)
        return BoundQuestionPresentation(
            presentation: self,
            rawChoices: rawShape.choices,
            governedSource: governedSource
        )
    }
}
