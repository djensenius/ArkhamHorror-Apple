// swiftlint:disable file_length function_body_length identifier_name nesting
import Foundation

/// Render-only semantic metadata bound to one authoritative raw question.
///
/// The backend remains the sole authority for legality, costs, mutable state, and answer
/// execution. A bound presentation only describes existing raw choice indices; callers still
/// submit ``BasicChoiceAnswer`` with the original source index and question version.
struct QuestionPresentation: Sendable, Equatable, Hashable {
    static let supportedProtocolVersion = 2

    let protocolVersion: Int
    let questionVersion: Int
    let questionKind: Kind
    let choiceCount: Int
    let choices: [Choice]
    let answer: Answer
    let selection: Selection?
    let groups: [Int]?
    let label: Label?
    let questionLabel: Label?
    let completionLabel: Label?
    let confirmLabel: Label?
    let backLabel: Label?
    let cardCode: String?
    let payCost: Cost?
    let questionSource: Source?
    let tooltip: String?
    let flavorText: FlavorText?
    let readCards: [String]?
    let readChoiceKind: ReadChoiceKind?
    let target: AmountTarget?
    let resolveTarget: JSONValue?
    let amountChoices: [AmountChoice]?
    let paymentChoices: [PaymentAmountChoice]?
    let usedInvestigators: [String]?
    let pointsRemaining: Int?
    let chosenSupplies: [String]?
    let resupply: Bool?
    let drawings: [DestinyDrawing]?
    let key: String?
    let value: JSONValue?
    let source: Source?
    let fromInvestigator: String?
    let fromInitialAmount: Int?
    let toInvestigator: String?
    let toInitialAmount: Int?
    let token: String?

    init(
        protocolVersion: Int,
        questionVersion: Int,
        questionKind: Kind,
        choiceCount: Int,
        choices: [Choice],
        answer: Answer = .singleChoice(alternateTags: nil),
        selection: Selection? = nil,
        groups: [Int]? = nil,
        label: Label? = nil,
        questionLabel: Label? = nil,
        completionLabel: Label? = nil,
        confirmLabel: Label? = nil,
        backLabel: Label? = nil,
        cardCode: String? = nil,
        payCost: Cost? = nil,
        questionSource: Source? = nil,
        tooltip: String? = nil,
        flavorText: FlavorText? = nil,
        readCards: [String]? = nil,
        readChoiceKind: ReadChoiceKind? = nil,
        target: AmountTarget? = nil,
        resolveTarget: JSONValue? = nil,
        amountChoices: [AmountChoice]? = nil,
        paymentChoices: [PaymentAmountChoice]? = nil,
        usedInvestigators: [String]? = nil,
        pointsRemaining: Int? = nil,
        chosenSupplies: [String]? = nil,
        resupply: Bool? = nil,
        drawings: [DestinyDrawing]? = nil,
        key: String? = nil,
        value: JSONValue? = nil,
        source: Source? = nil,
        fromInvestigator: String? = nil,
        fromInitialAmount: Int? = nil,
        toInvestigator: String? = nil,
        toInitialAmount: Int? = nil,
        token: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.questionVersion = questionVersion
        self.questionKind = questionKind
        self.choiceCount = choiceCount
        self.choices = choices
        self.answer = answer
        self.selection = selection
        self.groups = groups
        self.label = label
        self.questionLabel = questionLabel
        self.completionLabel = completionLabel
        self.confirmLabel = confirmLabel
        self.backLabel = backLabel
        self.cardCode = cardCode
        self.payCost = payCost
        self.questionSource = questionSource
        self.tooltip = tooltip
        self.flavorText = flavorText
        self.readCards = readCards
        self.readChoiceKind = readChoiceKind
        self.target = target
        self.resolveTarget = resolveTarget
        self.amountChoices = amountChoices
        self.paymentChoices = paymentChoices
        self.usedInvestigators = usedInvestigators
        self.pointsRemaining = pointsRemaining
        self.chosenSupplies = chosenSupplies
        self.resupply = resupply
        self.drawings = drawings
        self.key = key
        self.value = value
        self.source = source
        self.fromInvestigator = fromInvestigator
        self.fromInitialAmount = fromInitialAmount
        self.toInvestigator = toInvestigator
        self.toInitialAmount = toInitialAmount
        self.token = token
    }
}

extension QuestionPresentation {
    enum Kind: String, Sendable, Equatable, Hashable, Codable {
        case chooseAmounts
        case chooseDeck
        case chooseExchangeAmounts
        case chooseJoinDeck
        case chooseN
        case chooseOne
        case chooseOneAtATime
        case chooseOneAtATimeWithAuto
        case chooseOneFromEach
        case chooseOneWizard
        case choosePaymentAmounts
        case chooseSome
        case chooseSome1
        case chooseUpgradeDeck
        case chooseUpToN
        case continueCampaign
        case dropDown
        case pickCampaignSettings
        case pickCampaignSpecific
        case pickDestiny
        case pickScenarioSettings
        case pickScenarioSpecific
        case pickSupplies
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
        case auto
        case auxiliaryComponentLabel
        case cardPile
        case chaosTokenGroupChoice
        case chaosTokenLabel
        case chooseTarget
        case componentLabel
        case connectionLabel
        case costLabel
        case drawCard
        case drawEncounterCard
        case effectActionButton
        case endTurn
        case engage
        case evade
        case fight
        case gainResource
        case info
        case invalidLabel
        case investigate
        case keyLabel
        case localizedLabel
        case move
        case opaque
        case resolveForcedAbility
        case skillLabel
        case skipTriggers
        case startSkillTest
        case tarotLabel
        case useAbility
        case wizardChoice
    }

    struct Choice: Sendable, Equatable, Hashable {
        let sourceIndex: Int
        let kind: ChoiceKind
        let selectable: Bool
        let completesSelection: Bool?
        let actorID: String?
        let entity: Entity?
        let label: Label?
        let ability: Ability?
        let cost: Cost?
        let flippable: Bool?
        let face: String?
        let key: JSONValue?
        let skillType: SkillType?
        let connection: LocationSymbol?
        let tarotCard: TarotCard?
        let component: Component?
        let source: Source?
        let step: JSONValue?
        let tooltip: String?
        let cards: [PileCard]?
        let flavorText: FlavorText?
        let uiTag: String?
        let target: JSONValue?
        let groupIndex: Int?

        init(
            sourceIndex: Int,
            kind: ChoiceKind,
            selectable: Bool = true,
            completesSelection: Bool? = nil,
            actorID: String? = nil,
            entity: Entity? = nil,
            label: Label? = nil,
            ability: Ability? = nil,
            cost: Cost? = nil,
            flippable: Bool? = nil,
            face: String? = nil,
            key: JSONValue? = nil,
            skillType: SkillType? = nil,
            connection: LocationSymbol? = nil,
            tarotCard: TarotCard? = nil,
            component: Component? = nil,
            source: Source? = nil,
            step: JSONValue? = nil,
            tooltip: String? = nil,
            cards: [PileCard]? = nil,
            flavorText: FlavorText? = nil,
            uiTag: String? = nil,
            target: JSONValue? = nil,
            groupIndex: Int? = nil
        ) {
            self.sourceIndex = sourceIndex
            self.kind = kind
            self.selectable = selectable
            self.completesSelection = completesSelection
            self.actorID = actorID
            self.entity = entity
            self.label = label
            self.ability = ability
            self.cost = cost
            self.flippable = flippable
            self.face = face
            self.key = key
            self.skillType = skillType
            self.connection = connection
            self.tarotCard = tarotCard
            self.component = component
            self.source = source
            self.step = step
            self.tooltip = tooltip
            self.cards = cards
            self.flavorText = flavorText
            self.uiTag = uiTag
            self.target = target
            self.groupIndex = groupIndex
        }
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

    enum Answer: Sendable, Equatable, Hashable {
        case singleChoice(alternateTags: [String]?)
        case amounts
        case paymentAmounts
        case exchangeAmounts
        case deck(tags: [String])
        case standaloneSettings
        case campaignSettings
        case pickDestiny
        case campaignSpecific
        case scenarioSpecific
        case continueCampaign(tags: [String])
    }

    struct Selection: Sendable, Equatable, Hashable, Codable {
        let min: Int
        let max: Int
    }

    enum LabelKind: String, Sendable, Equatable, Hashable, Codable {
        case embeddedI18n
    }

    struct Label: Sendable, Equatable, Hashable {
        let kind: LabelKind
        let text: String
    }

    enum ReadChoiceKind: String, Sendable, Equatable, Hashable, Codable {
        case basic
        case chooseN
        case chooseUpToN
        case leadInvestigatorMustDecide
    }

    enum SkillType: String, Sendable, Equatable, Hashable, Codable {
        case willpower = "SkillWillpower"
        case intellect = "SkillIntellect"
        case combat = "SkillCombat"
        case agility = "SkillAgility"
        case wild = "SkillWild"
    }

    enum LocationSymbol: String, Sendable, Equatable, Hashable, Codable {
        case circle = "Circle"
        case square = "Square"
        case triangle = "Triangle"
        case plus = "Plus"
        case diamond = "Diamond"
        case squiggle = "Squiggle"
        case moon = "Moon"
        case hourglass = "Hourglass"
        case t = "T"
        case equals = "Equals"
        case heart = "Heart"
        case star = "Star"
        case droplet = "Droplet"
        case trefoil = "Trefoil"
        case spade = "Spade"
        case noSymbol = "NoSymbol"
    }

    struct TarotCard: Sendable, Equatable, Hashable, Codable {
        enum Facing: String, Sendable, Equatable, Hashable, Codable {
            case upright = "Upright"
            case reversed = "Reversed"
        }

        let facing: Facing
        let arcana: String
    }

    enum Component: Sendable, Equatable, Hashable {
        case investigator(investigatorID: String, tokenType: GameTokenType)
        case investigatorDeck(investigatorID: String)
        case asset(assetID: String, tokenType: GameTokenType)
    }

    enum GameTokenType: String, Sendable, Equatable, Hashable, Codable {
        case resource = "ResourceToken"
        case clue = "ClueToken"
        case damage = "DamageToken"
        case horror = "HorrorToken"
        case doom = "DoomToken"
    }

    struct Source: Sendable, Equatable, Hashable {
        let raw: JSONValue
        let entity: Entity?
    }

    struct FlavorText: Sendable, Equatable, Hashable, Codable {
        let title: String?
        let body: [JSONValue]
    }

    struct PileCard: Sendable, Equatable, Hashable, Codable {
        let cardID: String
        let cardOwner: String?
    }

    enum AmountTarget: Sendable, Equatable, Hashable {
        case min(Int)
        case max(Int)
        case total(Int)
        case oneOf([Int])
    }

    struct AmountChoice: Sendable, Equatable, Hashable, Codable {
        let choiceID: String
        let label: String
        let minBound: Int
        let maxBound: Int
    }

    struct PaymentAmountChoice: Sendable, Equatable, Hashable, Codable {
        let choiceID: String
        let investigatorID: String
        let min: Int
        let max: Int
        let title: Label
    }

    struct DestinyDrawing: Sendable, Equatable, Hashable, Codable {
        let scenario: JSONValue
        let tarot: TarotCard
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

        init(
            cardCode: String,
            index: Int,
            type: AbilityType,
            actions: [Action],
            canBeCancelled: Bool
        ) {
            self.cardCode = cardCode
            self.index = index
            self.type = type
            self.actions = actions
            self.canBeCancelled = canBeCancelled
        }
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
        return BoundQuestionPresentation(
            presentation: self,
            rawChoices: rawShape.choices
        )
    }
}

// swiftlint:enable file_length function_body_length identifier_name nesting
