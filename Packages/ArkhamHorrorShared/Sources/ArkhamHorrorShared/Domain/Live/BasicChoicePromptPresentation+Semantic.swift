// swiftlint:disable file_length line_length
import Foundation

struct BasicChoiceResolvedChoiceLabel: Sendable, Equatable {
    let title: String
    let subtitle: String?
    let systemImage: String
    let accessibilityLabel: String
}

extension QuestionPresentation {
    enum GenericSupport: Sendable, Equatable {
        case singleChoice
        case multiSelect
        case amounts
        case payment
        case exchange
        case deck
        case campaignSettings
        case deferred

        var isRenderableInCurrentClient: Bool {
            self == .singleChoice
        }
    }

    var genericSupport: GenericSupport {
        guard protocolVersion == Self.supportedProtocolVersion,
              questionKind != .unsupported
        else { return .deferred }
        return switch answer {
        case .singleChoice:
            .singleChoice
        case .amounts:
            .amounts
        case .paymentAmounts:
            .payment
        case .exchangeAmounts:
            .exchange
        case .deck:
            .deck
        case .standaloneSettings, .campaignSettings,
             .pickDestiny, .campaignSpecific, .scenarioSpecific,
             .continueCampaign:
            .campaignSettings
        }
    }

    var supportsCurrentGenericChoiceList: Bool {
        genericSupport.isRenderableInCurrentClient && choiceCount > 0
    }
}

extension BoundQuestionPresentation {
    var isRenderableInCurrentClient: Bool {
        presentation.supportsCurrentGenericChoiceList
            && !rawChoices.isEmpty
            && (!requiresSealedActionabilityOverlay || usesSealedActionabilityOverlay)
    }
}

extension BoundQuestionPresentation {
    func canActivateSemanticChoice(
        _ descriptor: QuestionPresentation.Choice,
        ownerID: PlayerID,
        projection: BoardProjection,
        labelResolution: BasicChoiceLabelResolution?
    ) -> Bool {
        guard case .singleChoice = presentation.answer,
              presentation.supportsCurrentGenericChoiceList,
              descriptor.selectable,
              labelResolution?.unavailableReason == nil
        else { return false }
        guard !requiresSealedActionabilityOverlay || usesSealedActionabilityOverlay else {
            return false
        }
        guard usesSealedActionabilityOverlay else { return true }
        return projection.isSemanticChoiceActionable(
            descriptor,
            ownerID: ownerID,
            labelResolution: labelResolution,
            governedSource: governedSource
        )
    }
}

extension BasicChoicePromptPresentation {
    var isRenderableQuestion: Bool {
        if let semanticPresentation {
            return semanticPresentation.isRenderableInCurrentClient
        }
        return question.supportedQuestion?.choices.isEmpty == false
    }

    var isStoryPrompt: Bool {
        if let semanticPresentation {
            return semanticPresentation.presentation.questionKind == .read
        }
        return question.supportedQuestion?.kind == .read
    }

    func headerTitle(in _: BoardProjection) -> String {
        guard let presentation = semanticPresentation?.presentation else {
            return isStoryPrompt ? "Story" : "Choose an action"
        }
        if let title = promptLabelResolutions["questionLabel"]?.title {
            return title
        }
        if let text = presentation.questionLabel?.text, !text.hasPrefix("$") {
            return text
        }
        switch presentation.questionKind {
        case .read:
            return "Story"
        case .chooseN, .chooseUpToN:
            return semanticLocalized(
                "semantic.question.title.selections",
                value: "Make selections"
            )
        case .chooseOneAtATime, .chooseOneAtATimeWithAuto:
            return "Choose one at a time"
        case .chooseOneFromEach:
            return "Choose one from each"
        case .playerWindowChooseOne, .windowChooseOne:
            return "Choose a reaction"
        case .chooseOne, .chooseOneWizard, .dropDown, .pickSupplies:
            return "Choose an action"
        case .chooseAmounts, .chooseDeck, .chooseExchangeAmounts, .chooseJoinDeck,
             .choosePaymentAmounts, .chooseSome, .chooseSome1, .chooseUpgradeDeck,
             .continueCampaign, .pickCampaignSettings, .pickCampaignSpecific,
             .pickDestiny, .pickScenarioSettings, .pickScenarioSpecific, .unsupported:
            return "Choose an action"
        }
    }

    func headerSubtitle(in projection: BoardProjection) -> String? {
        guard let presentation = semanticPresentation?.presentation else { return nil }
        var parts: [String] = []
        if let source = presentation.questionSource?.entity.flatMap({
            semanticEntityTitle($0, in: projection)
        }) {
            parts.append(source)
        }
        if let cost = presentation.payCost {
            parts.append("Cost: \(semanticCostSummary(cost, in: projection))")
        }
        if let cardCode = presentation.cardCode {
            if let cardName = semanticCardName(cardCode, in: projection) {
                parts.append(cardName)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    func questionHint() -> String? {
        guard let presentation = semanticPresentation?.presentation else { return nil }
        return selectionHint(for: presentation)
    }

    private func selectionHint(for presentation: QuestionPresentation) -> String? {
        guard let selection = presentation.selection else { return nil }
        switch presentation.questionKind {
        case .chooseN:
            return "Choose \(selection.max)"
        case .chooseUpToN:
            return "Choose up to \(selection.max)"
        case .chooseSome1:
            return "Choose at least \(selection.min)"
        case .chooseSome:
            return "Choose any number"
        case .chooseOneAtATime, .chooseOneAtATimeWithAuto:
            return "Choose one at a time"
        case .chooseOneFromEach:
            return "Choose one from each group"
        default:
            return nil
        }
    }

    static func makeChoices(
        question: BasicChoiceQuestionState,
        semanticPresentation: BoundQuestionPresentation?
    ) -> [BasicChoice] {
        guard let semanticPresentation else {
            return question.supportedQuestion?.choices ?? []
        }
        let parsedChoices = Dictionary(
            uniqueKeysWithValues: (question.supportedQuestion?.choices ?? []).map {
                ($0.index, $0)
            }
        )
        return semanticPresentation.rawChoices.enumerated().map { index, rawChoice in
            if let parsed = parsedChoices[index], parsed.rawValue == rawChoice {
                return parsed
            }
            return BasicChoice(
                index: index,
                rawValue: rawChoice,
                content: .unsupported(tag: Self.rawChoiceTag(rawChoice))
            )
        }
    }

    func displayTitle(for choice: BasicChoice, in projection: BoardProjection) -> String {
        resolvedChoiceLabel(for: choice, in: projection).title
    }

    func systemImage(for choice: BasicChoice) -> String {
        guard let semanticPresentation,
              let descriptor = semanticPresentation.descriptor(forSourceIndex: choice.index)
        else { return choice.systemImage }
        return semanticSystemImage(for: descriptor)
    }

    func accessibilityLabel(for choice: BasicChoice, in projection: BoardProjection) -> String {
        resolvedChoiceLabel(for: choice, in: projection).accessibilityLabel
    }

    func resolvedChoiceLabel(
        for choice: BasicChoice,
        in projection: BoardProjection
    ) -> BasicChoiceResolvedChoiceLabel {
        guard let semanticPresentation else {
            let title = BoardDisplayFormatting.choiceDisplayTitle(
                for: choice,
                in: projection,
                ownerID: ownerID,
                labelResolution: choiceLabelResolutions[choice.index]
            )
            return BasicChoiceResolvedChoiceLabel(
                title: title,
                subtitle: nil,
                systemImage: choice.systemImage,
                accessibilityLabel: title
            )
        }
        guard let descriptor = semanticPresentation.descriptor(forSourceIndex: choice.index) else {
            let title = semanticLocalized(
                "semantic.choice.unavailable.index",
                value: "Unavailable action (choice \(choice.index + 1))",
                arguments: [Int64(choice.index + 1)]
            )
            return BasicChoiceResolvedChoiceLabel(
                title: title,
                subtitle: nil,
                systemImage: "exclamationmark.triangle",
                accessibilityLabel: title
            )
        }
        var resolution = semanticChoiceLabel(
            for: descriptor,
            in: projection,
            labelResolution: choiceLabelResolutions[choice.index]
        )
        if let cost = descriptor.cost, descriptor.kind != .costLabel {
            let costSummary = semanticCostSummary(cost, in: projection)
            resolution = BasicChoiceResolvedChoiceLabel(
                title: semanticLocalized(
                    "semantic.choice.title.withCost",
                    value: "\(resolution.title) (\(costSummary))",
                    arguments: [resolution.title, costSummary]
                ),
                subtitle: resolution.subtitle,
                systemImage: resolution.systemImage,
                accessibilityLabel: semanticLocalized(
                    "semantic.choice.accessibility.withCost",
                    value: "\(resolution.accessibilityLabel), cost: \(costSummary)",
                    arguments: [resolution.accessibilityLabel, costSummary]
                )
            )
        }
        return resolution
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func semanticSystemImage(for descriptor: QuestionPresentation.Choice) -> String {
        switch descriptor.kind {
        case .advanceAct, .advanceAgenda: "arrow.up.circle.fill"
        case .applySkillTestResults: "checkmark.seal.fill"
        case .assignDamage: "heart.slash.fill"
        case .assignHorror: "brain.head.profile.fill"
        case .auto: "sparkles"
        case .auxiliaryComponentLabel, .componentLabel: "circle.grid.cross"
        case .cardPile: "rectangle.stack.badge.person.crop"
        case .chaosTokenGroupChoice, .chaosTokenLabel: "circle.hexagongrid.fill"
        case .chooseTarget: "scope"
        case .connectionLabel: "point.3.connected.trianglepath.dotted"
        case .costLabel: "creditcard"
        case .drawCard, .drawEncounterCard: "rectangle.stack"
        case .effectActionButton: "wand.and.stars"
        case .endTurn: "forward.end"
        case .engage: "person.2.fill"
        case .evade: "figure.run"
        case .fight: "burst.fill"
        case .gainResource: "circle.fill"
        case .info: "info.circle"
        case .invalidLabel: "nosign"
        case .investigate: "magnifyingglass"
        case .keyLabel: "key.fill"
        case .localizedLabel: "text.bubble.fill"
        case .move: "figure.walk"
        case .opaque: "questionmark.square.dashed"
        case .resolveForcedAbility: "exclamationmark.triangle.fill"
        case .skillLabel: "brain.head.profile"
        case .skipTriggers: "forward.end.alt"
        case .startSkillTest: "play.circle.fill"
        case .tarotLabel: "sparkles.rectangle.stack"
        case .useAbility: "bolt.circle.fill"
        case .wizardChoice: "wand.and.rays"
        }
    }

    func accessibilityHint(for choice: BasicChoice, in projection: BoardProjection) -> String {
        guard let semanticPresentation else {
            return BoardDisplayFormatting.choiceAccessibilityHint(
                for: choice,
                in: projection,
                ownerID: ownerID,
                storyResolution: storyResolution,
                labelResolution: choiceLabelResolutions[choice.index],
                canSubmit: canSubmit,
                statusMessage: statusMessage
            )
        }
        guard let descriptor = semanticPresentation.descriptor(
            forSourceIndex: choice.index
        ) else {
            return semanticLocalized(
                "semantic.choice.accessibility.missingDescription",
                value:
                "This choice has no semantic description and cannot be activated."
            )
        }
        let isActionable = isSemanticChoiceActionable(descriptor, in: projection)
        guard isActionable else {
            return semanticUnavailableAnnouncement(
                for: descriptor,
                labelResolution: choiceLabelResolutions[choice.index]
            )
        }
        guard canSubmit else {
            return statusMessage ?? semanticLocalized(
                "semantic.choice.accessibility.readOnly",
                value: "This choice is currently read-only."
            )
        }
        return semanticLocalized(
            "semantic.choice.accessibility.activatesIndex",
            value: "Activates choice \(choice.index + 1).",
            arguments: [Int64(choice.index + 1)]
        )
    }

    func isSemanticChoiceActionable(
        _ descriptor: QuestionPresentation.Choice,
        in projection: BoardProjection
    ) -> Bool {
        guard let semanticPresentation else { return false }
        return semanticPresentation.canActivateSemanticChoice(
            descriptor,
            ownerID: ownerID,
            projection: projection,
            labelResolution: choiceLabelResolutions[descriptor.sourceIndex]
        )
    }

    private static func rawChoiceTag(_ value: JSONValue) -> String? {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else { return nil }
        return tag
    }

    private func semanticChoiceLabel(
        for descriptor: QuestionPresentation.Choice,
        in projection: BoardProjection,
        labelResolution: BasicChoiceLabelResolution?
    ) -> BasicChoiceResolvedChoiceLabel {
        let title = semanticTitle(
            for: descriptor,
            in: projection,
            labelResolution: labelResolution
        )
        let subtitle = semanticSubtitle(
            for: descriptor,
            in: projection,
            labelResolution: labelResolution
        )
        let accessibilityLabel = subtitle.map { "\(title), \($0)" } ?? title
        return BasicChoiceResolvedChoiceLabel(
            title: title,
            subtitle: subtitle,
            systemImage: semanticSystemImage(for: descriptor),
            accessibilityLabel: accessibilityLabel
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func semanticTitle(
        for descriptor: QuestionPresentation.Choice,
        in projection: BoardProjection,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        switch descriptor.kind {
        case .advanceAct:
            semanticLocalized(
                "semantic.choice.title.advanceAct",
                value: "Advance act"
            )
        case .advanceAgenda:
            semanticLocalized(
                "semantic.choice.title.advanceAgenda",
                value: "Advance agenda"
            )
        case .applySkillTestResults:
            semanticLocalized(
                "semantic.choice.title.applyResults",
                value: "Apply results"
            )
        case .assignDamage:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.assignDamage",
                        value: "Assign damage to \($0)",
                        arguments: [$0]
                    )
                }
                ?? semanticLocalized(
                    "semantic.choice.title.assignDamage.generic",
                    value: "Assign damage"
                )
        case .assignHorror:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.assignHorror",
                        value: "Assign horror to \($0)",
                        arguments: [$0]
                    )
                }
                ?? semanticLocalized(
                    "semantic.choice.title.assignHorror.generic",
                    value: "Assign horror"
                )
        case .auto:
            semanticTitleFromLabel(
                descriptor,
                labelResolution: labelResolution,
                fallback: semanticLocalized("semantic.choice.title.auto", value: "Automatic choice")
            )
        case .auxiliaryComponentLabel, .componentLabel:
            semanticComponentTitle(descriptor.component, in: projection)
                ?? descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                ?? semanticLocalized("semantic.choice.title.component", value: "Component")
        case .cardPile:
            descriptor.cards.map { cards in
                semanticLocalized(
                    "semantic.choice.title.cardPile.count",
                    value: "Card pile (\(cards.count) cards)",
                    arguments: [Int64(cards.count)]
                )
            } ?? semanticLocalized("semantic.choice.title.cardPile", value: "Card pile")
        case .chaosTokenGroupChoice:
            semanticLocalized("semantic.choice.title.chaosTokenGroup", value: "Choose chaos token")
        case .chaosTokenLabel:
            descriptor.face ?? semanticLocalized("semantic.choice.title.chaosToken", value: "Chaos token")
        case .chooseTarget:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.chooseEntity",
                        value: "Choose \($0)",
                        arguments: [$0]
                    )
                }
                ?? descriptor.label.flatMap { _ in
                    semanticTitleFromLabel(
                        descriptor,
                        labelResolution: labelResolution,
                        fallback: nil
                    )
                }
                ?? semanticLocalized(
                    "semantic.choice.title.chooseTarget",
                    value: "Choose target"
                )
        case .connectionLabel:
            descriptor.connection.map(semanticConnectionTitle)
                ?? semanticLocalized("semantic.choice.title.connection", value: "Connection")
        case .costLabel:
            descriptor.cost.map { semanticCostSummary($0, in: projection) }
                ?? semanticLocalized("semantic.choice.title.cost", value: "Cost")
        case .drawCard:
            semanticLocalized(
                "semantic.choice.title.drawCard",
                value: "Draw a card"
            )
        case .effectActionButton:
            descriptor.tooltip.flatMap(semanticInlineLabel)
                ?? descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                ?? semanticLocalized("semantic.choice.title.effect", value: "Effect")
        case .drawEncounterCard:
            semanticLocalized(
                "semantic.choice.title.drawEncounterCard",
                value: "Draw encounter card"
            )
        case .endTurn:
            semanticLocalized(
                "semantic.choice.title.endTurn",
                value: "End turn"
            )
        case .engage:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }.map {
                semanticLocalized(
                    "semantic.choice.title.engageEntity",
                    value: "Engage \($0)",
                    arguments: [$0]
                )
            } ?? semanticLocalized(
                "semantic.choice.title.engage",
                value: "Engage"
            )
        case .evade:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }.map {
                semanticLocalized(
                    "semantic.choice.title.evadeEntity",
                    value: "Evade \($0)",
                    arguments: [$0]
                )
            } ?? semanticLocalized(
                "semantic.choice.title.evade",
                value: "Evade"
            )
        case .fight:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }.map {
                semanticLocalized(
                    "semantic.choice.title.fightEntity",
                    value: "Fight \($0)",
                    arguments: [$0]
                )
            } ?? semanticLocalized(
                "semantic.choice.title.fight",
                value: "Fight"
            )
        case .gainResource:
            semanticLocalized(
                "semantic.choice.title.gainResource",
                value: "Gain a resource"
            )
        case .info:
            semanticInfoTitle(for: descriptor)
        case .invalidLabel:
            semanticTitleFromLabel(
                descriptor,
                labelResolution: labelResolution,
                fallback: semanticLocalized("semantic.choice.title.invalid", value: "Unavailable action")
            )
        case .investigate:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }.map {
                semanticLocalized(
                    "semantic.choice.title.investigateLocation",
                    value: "Investigate \($0)",
                    arguments: [$0]
                )
            } ?? semanticLocalized(
                "semantic.choice.title.investigate",
                value: "Investigate"
            )
        case .keyLabel:
            descriptor.key.flatMap(semanticKeyTitle)
                ?? semanticLocalized("semantic.choice.title.key", value: "Key")
        case .localizedLabel:
            semanticTitleFromLabel(
                descriptor,
                labelResolution: labelResolution,
                fallback: semanticLocalized(
                    "semantic.choice.title.genericIndexed",
                    value: "Choice \(descriptor.sourceIndex + 1)",
                    arguments: [Int64(descriptor.sourceIndex + 1)]
                )
            )
        case .move:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.move",
                        value: "Move to \($0)",
                        arguments: [$0]
                    )
                }
                ?? semanticLocalized(
                    "semantic.choice.title.move.generic",
                    value: "Move"
                )
        case .resolveForcedAbility:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.resolveForcedAbility",
                        value: "Resolve forced ability at \($0)",
                        arguments: [$0]
                    )
                }
                ?? semanticLocalized(
                    "semantic.choice.title.resolveForcedAbility.generic",
                    value: "Resolve forced ability"
                )
        case .opaque:
            descriptor.uiTag
                ?? semanticLocalized(
                    "semantic.choice.title.genericIndexed",
                    value: "Choice \(descriptor.sourceIndex + 1)",
                    arguments: [Int64(descriptor.sourceIndex + 1)]
                )
        case .skillLabel:
            semanticSkillLabelTitle(descriptor, labelResolution: labelResolution)
        case .skipTriggers:
            semanticLocalized(
                "semantic.choice.title.skipTriggers",
                value: "Skip triggers"
            )
        case .startSkillTest:
            semanticLocalized(
                "semantic.choice.title.startSkillTest",
                value: "Start skill test"
            )
        case .tarotLabel:
            descriptor.tarotCard.map(semanticTarotTitle)
                ?? semanticLocalized("semantic.choice.title.tarot", value: "Tarot")
        case .useAbility:
            semanticAbilityTitle(descriptor.ability, in: projection)
                ?? semanticLocalized(
                    "semantic.choice.title.useAbility",
                    value: "Use ability"
                )
        case .wizardChoice:
            semanticTitleFromLabel(
                descriptor,
                labelResolution: labelResolution,
                fallback: semanticLocalized("semantic.choice.title.wizard", value: "Wizard choice")
            )
        }
    }

    private func semanticTitleFromLabel(
        _ descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?,
        fallback: String?
    ) -> String {
        if let title = labelResolution?.title {
            return title
        }
        if let text = descriptor.label?.text {
            if let inline = semanticInlineLabel(text) {
                return inline
            }
        }
        if labelResolution?.unavailableReason != nil {
            return fallback ?? semanticLocalized(
                "semantic.choice.title.genericIndexed",
                value: "Choice \(descriptor.sourceIndex + 1)",
                arguments: [Int64(descriptor.sourceIndex + 1)]
            )
        }
        return fallback ?? semanticLocalized(
            "semantic.choice.title.genericIndexed",
            value: "Choice \(descriptor.sourceIndex + 1)",
            arguments: [Int64(descriptor.sourceIndex + 1)]
        )
    }

    private func semanticSubtitle(
        for descriptor: QuestionPresentation.Choice,
        in projection: BoardProjection,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String? {
        if descriptor.kind == .info {
            return semanticInfoSubtitle(for: descriptor)
        }
        if descriptor.kind == .invalidLabel {
            return semanticLocalized(
                "semantic.choice.subtitle.invalid",
                value: "Not selectable"
            )
        }
        if let tooltip = descriptor.tooltip.flatMap(semanticInlineLabel) {
            let title = semanticTitle(
                for: descriptor,
                in: projection,
                labelResolution: labelResolution
            )
            if tooltip != title {
                return tooltip
            }
        }
        if let ability = descriptor.ability {
            return semanticAbilitySubtitle(ability)
        }
        if let component = descriptor.component {
            return semanticComponentSubtitle(component, in: projection)
        }
        if descriptor.completesSelection == true {
            return semanticLocalized(
                "semantic.choice.subtitle.completesSelection",
                value: "Completes this selection"
            )
        }
        return nil
    }

    private func semanticInlineLabel(_ text: String) -> String? {
        if text.hasPrefix("$") {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return semanticReplacingChaosTokenPlaceholders(in: trimmed)
    }

    private func semanticReplacingChaosTokenPlaceholders(in text: String) -> String {
        let replacements = [
            "{skull}": "Skull",
            "{cultist}": "Cultist",
            "{tablet}": "Tablet",
            "{elderThing}": "Elder Thing",
            "{autoFail}": "Auto-fail",
            "{elderSign}": "Elder Sign",
            "{curse}": "Curse",
            "{bless}": "Bless",
            "{frost}": "Frost",
        ]
        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private func semanticSkillLabelTitle(
        _ descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        let skill = descriptor.skillType.map(semanticSkillTitle)
        guard let label = descriptor.label.map({ _ in
            semanticTitleFromLabel(descriptor, labelResolution: labelResolution, fallback: nil)
        }) else {
            return skill ?? semanticLocalized("semantic.choice.title.skill", value: "Skill")
        }
        guard let skill else { return label }
        return semanticLocalized(
            "semantic.choice.title.skillWithLabel",
            value: "Use \(skill): \(label)",
            arguments: [skill, label]
        )
    }

    private func semanticSkillTitle(_ skill: QuestionPresentation.SkillType) -> String {
        switch skill {
        case .willpower: "Willpower"
        case .intellect: "Intellect"
        case .combat: "Combat"
        case .agility: "Agility"
        case .wild: "Wild"
        }
    }

    private func semanticConnectionTitle(
        _ connection: QuestionPresentation.LocationSymbol
    ) -> String {
        switch connection {
        case .noSymbol: "No connection symbol"
        default: connection.rawValue
        }
    }

    private func semanticKeyTitle(_ key: JSONValue) -> String? {
        guard case let .object(object) = key,
              case let .string(tag)? = object["tag"]
        else { return nil }
        let base = tag.replacingOccurrences(of: "Key", with: " key")
        return splitCamelCase(base)
    }

    private func semanticTarotTitle(_ tarot: QuestionPresentation.TarotCard) -> String {
        let arcana = semanticTarotArcanaTitle(tarot.arcana)
        switch tarot.facing {
        case .upright: return arcana
        case .reversed: return "\(arcana) (reversed)"
        }
    }

    private func semanticTarotArcanaTitle(_ raw: String) -> String {
        let titles = [
            "TheFool0": "The Fool",
            "TheMagicianI": "The Magician",
            "TheHighPriestessII": "The High Priestess",
            "TheEmpressIII": "The Empress",
            "TheEmperorIV": "The Emperor",
            "TheHierophantV": "The Hierophant",
            "TheLoversVI": "The Lovers",
            "TheChariotVII": "The Chariot",
            "StrengthVIII": "Strength",
            "TheHermitIX": "The Hermit",
            "WheelOfFortuneX": "Wheel of Fortune",
            "JusticeXI": "Justice",
            "TheHangedManXII": "The Hanged Man",
            "DeathXIII": "Death",
            "TemperanceXIV": "Temperance",
            "TheDevilXV": "The Devil",
            "TheTowerXVI": "The Tower",
            "TheStarXVII": "The Star",
            "TheMoonXVIII": "The Moon",
            "TheSunXIX": "The Sun",
            "JudgementXX": "Judgement",
            "TheWorldXXI": "The World",
        ]
        return titles[raw] ?? splitCamelCase(raw)
    }

    private func semanticAbilityTitle(
        _ ability: QuestionPresentation.Ability?,
        in projection: BoardProjection
    ) -> String? {
        guard let ability else { return nil }
        let card = semanticCardName(ability.cardCode, in: projection) ?? ability.cardCode
        return semanticLocalized(
            "semantic.choice.title.ability",
            value: "Use \(card) ability \(ability.index)",
            arguments: [card, Int64(ability.index)]
        )
    }

    private func semanticAbilitySubtitle(_ ability: QuestionPresentation.Ability) -> String {
        var parts = [splitCamelCase(ability.type.rawValue)]
        if !ability.actions.isEmpty {
            parts.append(ability.actions.map { splitCamelCase($0.rawValue) }.joined(separator: ", "))
        }
        return parts.joined(separator: " • ")
    }

    private func semanticComponentTitle(
        _ component: QuestionPresentation.Component?,
        in projection: BoardProjection
    ) -> String? {
        guard let component else { return nil }
        switch component {
        case let .investigator(investigatorID, tokenType):
            let token = semanticTokenTitle(tokenType)
            let name = semanticEntityTitle(
                .init(kind: .investigator, id: investigatorID),
                in: projection
            ) ?? "investigator"
            return "\(token) on \(name)"
        case let .asset(assetID, tokenType):
            let token = semanticTokenTitle(tokenType)
            let name = semanticEntityTitle(.init(kind: .asset, id: assetID), in: projection)
                ?? "asset"
            return "\(token) on \(name)"
        case let .investigatorDeck(investigatorID):
            let name = semanticEntityTitle(
                .init(kind: .investigator, id: investigatorID),
                in: projection
            ) ?? "investigator"
            return "\(name)'s deck"
        }
    }

    private func semanticComponentSubtitle(
        _ component: QuestionPresentation.Component,
        in _: BoardProjection
    ) -> String? {
        switch component {
        case let .investigator(_, tokenType), let .asset(_, tokenType):
            semanticTokenTitle(tokenType)
        case .investigatorDeck:
            nil
        }
    }

    private func semanticTokenTitle(_ token: QuestionPresentation.GameTokenType) -> String {
        switch token {
        case .resource: "Resources"
        case .clue: "Clues"
        case .damage: "Damage"
        case .horror: "Horror"
        case .doom: "Doom"
        }
    }

    private func semanticInfoTitle(for descriptor: QuestionPresentation.Choice) -> String {
        let resolved = choiceFlavorResolutions[descriptor.sourceIndex]?.story
        if let title = resolved?.title?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !title.isEmpty {
                return title
            }
        }
        if let title = descriptor.flavorText?.title {
            if let inline = semanticInlineLabel(title) {
                return inline
            }
        }
        if let body = semanticFlavorBodySummary(for: descriptor) {
            return body
        }
        return semanticLocalized("semantic.choice.title.info", value: "Information")
    }

    private func semanticInfoSubtitle(for descriptor: QuestionPresentation.Choice) -> String? {
        let inlineTitle: String? = if let rawTitle = descriptor.flavorText?.title {
            semanticInlineLabel(rawTitle)
        } else {
            nil
        }
        guard let title = choiceFlavorResolutions[descriptor.sourceIndex]?.story?.title
            ?? inlineTitle,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let body = semanticFlavorBodySummary(for: descriptor),
            body != title
        else { return nil }
        return body
    }

    private func semanticFlavorBodySummary(for descriptor: QuestionPresentation.Choice) -> String? {
        if let entry = choiceFlavorResolutions[descriptor.sourceIndex]?.story?.body.first {
            if let text = semanticStoryEntrySummary(entry) {
                return text
            }
        }
        return semanticFlavorSummary(descriptor.flavorText)
    }

    private func semanticStoryEntrySummary(_ entry: ResolvedStoryEntry) -> String? {
        let text: String = switch entry {
        case let .text(value):
            value
        case let .nodes(nodes), let .heading(_, nodes):
            nodes.map(\.plainText).joined()
        case let .list(items):
            items.compactMap { semanticStoryEntrySummary($0.entry) }.joined(separator: "; ")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func semanticFlavorSummary(_ flavorText: QuestionPresentation.FlavorText?) -> String? {
        guard let first = flavorText?.body.first,
              case let .object(object) = first,
              case let .string(text)? = object["text"],
              let inline = semanticInlineLabel(text)
        else { return nil }
        return inline
    }

    private func semanticCardName(_ rawCardCode: String, in projection: BoardProjection) -> String? {
        guard let code = try? CardCode(rawCardCode) else { return nil }
        return cardCatalog?.displayName(for: code)
            ?? projection.handCardsByPlayer.values.compactMap { $0.values.first {
                $0.cardCode == code
            }?.displayName }.first
            ?? projection.inPlayCardsByPlayer.values.flatMap(\.self).first {
                $0.cardCode == code
            }?.displayName
    }

    private func splitCamelCase(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            let needsSeparator = CharacterSet.uppercaseLetters.contains(scalar)
                && !result.isEmpty && result.last != " "
            if needsSeparator {
                result.append(" ")
            }
            result.append(String(scalar))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
    }

    func semanticLocalized(
        _ key: StaticString,
        value: String.LocalizationValue,
        arguments: [CVarArg] = []
    ) -> String {
        let locale = semanticLocaleIdentifier.map(Locale.init(identifier:)) ?? .current
        guard let bundle = semanticLocalizationBundle else {
            return String(
                localized: key,
                defaultValue: value,
                bundle: .module,
                locale: locale
            )
        }
        // Resolve the chosen .lproj directly because Xcode 26 can ignore an injected locale
        // when String(localized:) is given a SwiftPM resource sub-bundle.
        let keyString = String(describing: key)
        let format = bundle.localizedString(
            forKey: keyString,
            value: nil,
            table: nil
        )
        guard format != keyString else {
            return String(
                localized: key,
                defaultValue: value,
                bundle: .module,
                locale: locale
            )
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    private var semanticLocalizationBundle: Bundle? {
        guard let semanticLocaleIdentifier else { return nil }
        var candidates = [semanticLocaleIdentifier]
        if let language = semanticLocaleIdentifier.split(separator: "-").first {
            candidates.append(String(language))
        }
        candidates.append("en")
        for candidate in candidates {
            let path = Bundle.module.path(
                forResource: candidate,
                ofType: "lproj"
            )
            guard let path, let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        return nil
    }
}

// swiftlint:enable file_length line_length
