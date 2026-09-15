import Foundation

extension BasicChoicePromptPresentation {
    var isRenderableQuestion: Bool {
        if let semanticPresentation {
            return semanticPresentation.presentation.questionKind != .unsupported
        }
        return question.supportedQuestion != nil
    }

    var isStoryPrompt: Bool {
        if let semanticPresentation {
            return semanticPresentation.presentation.questionKind == .read
        }
        return question.supportedQuestion?.kind == .read
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
        guard let semanticPresentation else {
            return BoardDisplayFormatting.choiceDisplayTitle(
                for: choice,
                in: projection,
                ownerID: ownerID,
                labelResolution: choiceLabelResolutions[choice.index]
            )
        }
        guard let descriptor = semanticPresentation.descriptor(
            forSourceIndex: choice.index
        ) else {
            return semanticLocalized("Unavailable action (choice \(choice.index + 1))")
        }
        let title = semanticTitle(
            for: descriptor,
            in: projection,
            labelResolution: choiceLabelResolutions[choice.index]
        )
        guard let cost = descriptor.cost else { return title }
        let costSummary = semanticCostSummary(cost, in: projection)
        return semanticLocalized("\(title) (\(costSummary))")
    }

    // swiftlint:disable:next cyclomatic_complexity
    func systemImage(for choice: BasicChoice) -> String {
        guard let semanticPresentation else { return choice.systemImage }
        guard let descriptor = semanticPresentation.descriptor(
            forSourceIndex: choice.index
        ) else {
            return "exclamationmark.triangle"
        }
        return switch descriptor.kind {
        case .advanceAct, .advanceAgenda: "arrow.up.circle.fill"
        case .applySkillTestResults: "checkmark.seal.fill"
        case .chooseTarget: "scope"
        case .drawCard: "rectangle.stack"
        case .endTurn: "forward.end"
        case .engage: "person.2.fill"
        case .evade: "figure.run"
        case .fight: "burst.fill"
        case .gainResource: "circle.fill"
        case .investigate: "magnifyingglass"
        case .localizedLabel: "text.bubble.fill"
        case .skipTriggers: "forward.end.alt"
        case .startSkillTest: "play.circle.fill"
        case .useAbility: "bolt.circle.fill"
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
                "This choice has no semantic description and cannot be activated."
            )
        }
        guard projection.isSemanticChoiceActionable(
            descriptor,
            ownerID: ownerID,
            labelResolution: choiceLabelResolutions[choice.index]
        ) else {
            return semanticUnavailableAnnouncement(
                for: descriptor,
                labelResolution: choiceLabelResolutions[choice.index]
            )
        }
        guard canSubmit else {
            return statusMessage ?? semanticLocalized("This choice is currently read-only.")
        }
        return semanticLocalized("Activates choice \(choice.index + 1).")
    }

    private static func rawChoiceTag(_ value: JSONValue) -> String? {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else { return nil }
        return tag
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func semanticTitle(
        for descriptor: QuestionPresentation.Choice,
        in projection: BoardProjection,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        switch descriptor.kind {
        case .advanceAct:
            semanticLocalized("Advance act")
        case .advanceAgenda:
            semanticLocalized("Advance agenda")
        case .applySkillTestResults:
            semanticLocalized("Apply results")
        case .chooseTarget:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map { semanticLocalized("Choose \($0)") }
                ?? semanticLocalized("Choose target")
        case .drawCard:
            semanticLocalized("Draw a card")
        case .endTurn:
            semanticLocalized("End turn")
        case .engage:
            semanticLocalized("Engage")
        case .evade:
            semanticLocalized("Evade")
        case .fight:
            semanticLocalized("Fight")
        case .gainResource:
            semanticLocalized("Gain a resource")
        case .investigate:
            semanticLocalized("Investigate")
        case .localizedLabel:
            labelResolution?.title ?? semanticLocalized("Unavailable action")
        case .skipTriggers:
            semanticLocalized("Skip triggers")
        case .startSkillTest:
            semanticLocalized("Start skill test")
        case .useAbility:
            semanticLocalized("Use ability")
        }
    }

    private func semanticEntityTitle(
        _ entity: QuestionPresentation.Entity,
        in projection: BoardProjection
    ) -> String? {
        switch entity.kind {
        case .location:
            guard let id = semanticLocationID(entity.id) else { return nil }
            return projection.locations.first(where: { $0.id == id })?.displayLabel
                ?? projection.enemyLocations.first(where: { $0.id == id })?.displayLabel
        case .investigator:
            guard let id = semanticInvestigatorID(entity.id) else { return nil }
            return projection.investigators.first(where: { $0.id == id })?.displayName
        case .card:
            guard let id = semanticWireCardID(entity.id) else { return nil }
            return projection.handCardsByPlayer[ownerID]?[id]?.displayLabel
        case .scenario:
            return projection.scenario?.displayName
        case .act, .agenda, .asset, .cardCode, .effect, .enemy, .event, .player, .skill,
             .story, .treachery:
            return nil
        }
    }

    private enum SemanticCostComposition {
        case all
        case choice
    }

    private func semanticCostSummary(
        _ cost: QuestionPresentation.Cost,
        in projection: BoardProjection,
        enclosingComposition: SemanticCostComposition? = nil
    ) -> String {
        switch cost {
        case .free:
            return semanticLocalized("free")
        case let .action(amount):
            return semanticCount(amount, singular: "action", plural: "actions")
        case let .resource(amount):
            return semanticCount(amount, singular: "resource", plural: "resources")
        case let .clue(amount):
            return semanticAmountSummary(amount, singular: "clue", plural: "clues")
        case let .groupClue(amount, scope):
            let amountSummary = semanticAmountSummary(
                amount, singular: "clue", plural: "clues"
            )
            let scopeSummary = semanticScopeSummary(scope, in: projection)
            return semanticLocalized("\(amountSummary) \(scopeSummary)")
        case let .groupResource(amount, scope):
            let amountSummary = semanticAmountSummary(
                amount, singular: "resource", plural: "resources"
            )
            let scopeSummary = semanticScopeSummary(scope, in: projection)
            return semanticLocalized("\(amountSummary) \(scopeSummary)")
        case let .all(costs):
            return semanticCompositeCostSummary(
                costs,
                composition: .all,
                in: projection,
                enclosingComposition: enclosingComposition
            )
        case let .choice(costs):
            return semanticCompositeCostSummary(
                costs,
                composition: .choice,
                in: projection,
                enclosingComposition: enclosingComposition
            )
        case .other:
            return semanticLocalized("additional cost")
        }
    }

    private func semanticCompositeCostSummary(
        _ costs: [QuestionPresentation.Cost],
        composition: SemanticCostComposition,
        in projection: BoardProjection,
        enclosingComposition: SemanticCostComposition?
    ) -> String {
        let summaries = costs.map {
            semanticCostSummary(
                $0,
                in: projection,
                enclosingComposition: composition
            )
        }
        guard let first = summaries.first else { return "" }
        let summary = summaries.dropFirst().reduce(first) { partial, next in
            switch composition {
            case .all:
                semanticLocalized("\(partial) and \(next)")
            case .choice:
                semanticLocalized("\(partial) or \(next)")
            }
        }
        guard let enclosingComposition, enclosingComposition != composition else {
            return summary
        }
        return "(\(summary))"
    }

    private func semanticAmountSummary(
        _ amount: QuestionPresentation.Amount,
        singular: String.LocalizationValue,
        plural: String.LocalizationValue
    ) -> String {
        switch amount {
        case let .fixed(value):
            return semanticCount(value, singular: singular, plural: plural)
        case let .perPlayer(value):
            return semanticLocalized(
                "\(semanticCount(value, singular: singular, plural: plural)) per investigator"
            )
        case let .fixedPlusPerPlayer(fixed, perPlayer):
            let fixedSummary = semanticCount(fixed, singular: singular, plural: plural)
            let perPlayerSummary = semanticCount(
                perPlayer, singular: singular, plural: plural
            )
            return semanticLocalized(
                "\(fixedSummary) + \(perPlayerSummary) per investigator"
            )
        case let .byPlayerCount(values):
            let counts = values.map(String.init).joined(separator: "/")
            let pluralUnit = semanticLocalized(plural)
            return semanticLocalized("\(counts) \(pluralUnit) by player count")
        case .variable:
            return semanticLocalized("X \(semanticLocalized(plural))")
        case .star:
            return semanticLocalized("★ \(semanticLocalized(plural))")
        case .unknown:
            return semanticLocalized("an unknown number of \(semanticLocalized(plural))")
        }
    }

    private func semanticScopeSummary(
        _ scope: QuestionPresentation.Scope,
        in projection: BoardProjection
    ) -> String {
        switch scope {
        case .anywhere:
            return semanticLocalized("from anywhere")
        case .sameLocation:
            return semanticLocalized("at the same location")
        case let .location(rawID):
            guard let id = semanticLocationID(rawID) else {
                return semanticLocalized("at the specified location")
            }
            if let location = projection.locations.first(where: { $0.id == id }) {
                return semanticLocalized("at \(location.displayLabel)")
            }
            if let location = projection.enemyLocations.first(where: { $0.id == id }) {
                return semanticLocalized("at \(location.displayLabel)")
            }
            return semanticLocalized("at the specified location")
        case .other:
            return semanticLocalized("from the required area")
        }
    }

    private func semanticCount(
        _ value: Int,
        singular: String.LocalizationValue,
        plural: String.LocalizationValue
    ) -> String {
        let unit = semanticLocalized(value == 1 ? singular : plural)
        return semanticLocalized("\(value) \(unit)")
    }

    private func semanticUnavailableAnnouncement(
        for descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        if descriptor.kind == .localizedLabel {
            return labelResolution?.announcement
                ?? semanticLocalized("The text for this choice is not currently available.")
        }
        switch descriptor.kind {
        case .advanceAct:
            return semanticLocalized(
                "The act or investigator for this choice is not currently available."
            )
        case .advanceAgenda:
            return semanticLocalized(
                "The agenda or investigator for this choice is not currently available."
            )
        case .fight, .evade, .engage:
            return semanticLocalized(
                "The enemy or investigator for this choice is not currently available."
            )
        case .investigate:
            return semanticLocalized(
                "The location or investigator for this choice is not currently available."
            )
        case .chooseTarget:
            return semanticLocalized("The target for this choice is not currently available.")
        case .drawCard, .endTurn, .gainResource, .skipTriggers, .startSkillTest, .useAbility:
            return semanticLocalized(
                "The investigator for this choice is not currently available."
            )
        case .applySkillTestResults:
            return semanticLocalized("This choice is not currently available.")
        case .localizedLabel:
            return semanticLocalized("The text for this choice is not currently available.")
        }
    }

    private func semanticLocalized(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .module)
    }

    private func semanticLocationID(_ raw: String) -> LocationID? {
        LocationID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticWireCardID(_ raw: String) -> WireCardID? {
        WireCardID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticInvestigatorID(_ raw: String) -> InvestigatorID? {
        guard let code = try? CardCode(raw) else { return nil }
        return InvestigatorID(code)
    }
}
