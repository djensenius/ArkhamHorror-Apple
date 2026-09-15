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
            return "Unavailable action (choice \(choice.index + 1))"
        }
        let title = semanticTitle(
            for: descriptor,
            in: projection,
            labelResolution: choiceLabelResolutions[choice.index]
        )
        guard let cost = descriptor.cost else { return title }
        return "\(title) (\(semanticCostSummary(cost, in: projection)))"
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
            return "This choice has no semantic description and cannot be activated."
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
            return statusMessage ?? "This choice is currently read-only."
        }
        return "Activates choice \(choice.index + 1)."
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
            "Advance act"
        case .advanceAgenda:
            "Advance agenda"
        case .applySkillTestResults:
            "Apply results"
        case .chooseTarget:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map { "Choose \($0)" } ?? "Choose target"
        case .drawCard:
            "Draw a card"
        case .endTurn:
            "End turn"
        case .engage:
            "Engage"
        case .evade:
            "Evade"
        case .fight:
            "Fight"
        case .gainResource:
            "Gain a resource"
        case .investigate:
            "Investigate"
        case .localizedLabel:
            labelResolution?.title ?? "Unavailable action"
        case .skipTriggers:
            "Skip triggers"
        case .startSkillTest:
            "Start skill test"
        case .useAbility:
            "Use ability"
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

        var separator: String {
            switch self {
            case .all: " and "
            case .choice: " or "
            }
        }
    }

    private func semanticCostSummary(
        _ cost: QuestionPresentation.Cost,
        in projection: BoardProjection,
        enclosingComposition: SemanticCostComposition? = nil
    ) -> String {
        switch cost {
        case .free:
            "free"
        case let .action(amount):
            semanticCount(amount, singular: "action", plural: "actions")
        case let .resource(amount):
            semanticCount(amount, singular: "resource", plural: "resources")
        case let .clue(amount):
            semanticAmountSummary(amount, singular: "clue", plural: "clues")
        case let .groupClue(amount, scope):
            "\(semanticAmountSummary(amount, singular: "clue", plural: "clues")) "
                + semanticScopeSummary(scope, in: projection)
        case let .groupResource(amount, scope):
            "\(semanticAmountSummary(amount, singular: "resource", plural: "resources")) "
                + semanticScopeSummary(scope, in: projection)
        case let .all(costs):
            semanticCompositeCostSummary(
                costs,
                composition: .all,
                in: projection,
                enclosingComposition: enclosingComposition
            )
        case let .choice(costs):
            semanticCompositeCostSummary(
                costs,
                composition: .choice,
                in: projection,
                enclosingComposition: enclosingComposition
            )
        case .other:
            "additional cost"
        }
    }

    private func semanticCompositeCostSummary(
        _ costs: [QuestionPresentation.Cost],
        composition: SemanticCostComposition,
        in projection: BoardProjection,
        enclosingComposition: SemanticCostComposition?
    ) -> String {
        let summary = costs.map {
            semanticCostSummary(
                $0,
                in: projection,
                enclosingComposition: composition
            )
        }.joined(separator: composition.separator)
        guard let enclosingComposition, enclosingComposition != composition else {
            return summary
        }
        return "(\(summary))"
    }

    private func semanticAmountSummary(
        _ amount: QuestionPresentation.Amount,
        singular: String,
        plural: String
    ) -> String {
        switch amount {
        case let .fixed(value):
            semanticCount(value, singular: singular, plural: plural)
        case let .perPlayer(value):
            "\(semanticCount(value, singular: singular, plural: plural)) per investigator"
        case let .fixedPlusPerPlayer(fixed, perPlayer):
            "\(semanticCount(fixed, singular: singular, plural: plural)) + "
                + "\(semanticCount(perPlayer, singular: singular, plural: plural)) per investigator"
        case let .byPlayerCount(values):
            "\(values.map(String.init).joined(separator: "/")) \(plural) by player count"
        case .variable:
            "X \(plural)"
        case .star:
            "★ \(plural)"
        case .unknown:
            "an unknown number of \(plural)"
        }
    }

    private func semanticScopeSummary(
        _ scope: QuestionPresentation.Scope,
        in projection: BoardProjection
    ) -> String {
        switch scope {
        case .anywhere:
            return "from anywhere"
        case .sameLocation:
            return "at the same location"
        case let .location(rawID):
            guard let id = semanticLocationID(rawID) else {
                return "at the specified location"
            }
            if let location = projection.locations.first(where: { $0.id == id }) {
                return "at \(location.displayLabel)"
            }
            if let location = projection.enemyLocations.first(where: { $0.id == id }) {
                return "at \(location.displayLabel)"
            }
            return "at the specified location"
        case .other:
            return "from the required area"
        }
    }

    private func semanticCount(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    private func semanticUnavailableAnnouncement(
        for descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        if descriptor.kind == .localizedLabel {
            return labelResolution?.announcement
                ?? "The text for this choice is not currently available."
        }
        switch descriptor.kind {
        case .advanceAct:
            return "The act or investigator for this choice is not currently available."
        case .advanceAgenda:
            return "The agenda or investigator for this choice is not currently available."
        case .fight, .evade, .engage:
            return "The enemy or investigator for this choice is not currently available."
        case .investigate:
            return "The location or investigator for this choice is not currently available."
        case .chooseTarget:
            return "The target for this choice is not currently available."
        case .drawCard, .endTurn, .gainResource, .skipTriggers, .startSkillTest, .useAbility:
            return "The investigator for this choice is not currently available."
        case .applySkillTestResults:
            return "This choice is not currently available."
        case .localizedLabel:
            return "The text for this choice is not currently available."
        }
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
