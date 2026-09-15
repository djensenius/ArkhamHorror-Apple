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
            return semanticLocalized(
                "semantic.choice.unavailable.index",
                value: "Unavailable action (choice \(choice.index + 1))"
            )
        }
        let title = semanticTitle(
            for: descriptor,
            in: projection,
            labelResolution: choiceLabelResolutions[choice.index]
        )
        guard let cost = descriptor.cost else { return title }
        let costSummary = semanticCostSummary(cost, in: projection)
        return semanticLocalized(
            "semantic.choice.title.withCost",
            value: "\(title) (\(costSummary))"
        )
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
                "semantic.choice.accessibility.missingDescription",
                value:
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
            return statusMessage ?? semanticLocalized(
                "semantic.choice.accessibility.readOnly",
                value: "This choice is currently read-only."
            )
        }
        return semanticLocalized(
            "semantic.choice.accessibility.activatesIndex",
            value: "Activates choice \(choice.index + 1)."
        )
    }

    private static func rawChoiceTag(_ value: JSONValue) -> String? {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else { return nil }
        return tag
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
        case .chooseTarget:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.chooseEntity",
                        value: "Choose \($0)"
                    )
                }
                ?? semanticLocalized(
                    "semantic.choice.title.chooseTarget",
                    value: "Choose target"
                )
        case .drawCard:
            semanticLocalized(
                "semantic.choice.title.drawCard",
                value: "Draw a card"
            )
        case .endTurn:
            semanticLocalized(
                "semantic.choice.title.endTurn",
                value: "End turn"
            )
        case .engage:
            semanticLocalized(
                "semantic.choice.title.engage",
                value: "Engage"
            )
        case .evade:
            semanticLocalized(
                "semantic.choice.title.evade",
                value: "Evade"
            )
        case .fight:
            semanticLocalized(
                "semantic.choice.title.fight",
                value: "Fight"
            )
        case .gainResource:
            semanticLocalized(
                "semantic.choice.title.gainResource",
                value: "Gain a resource"
            )
        case .investigate:
            semanticLocalized(
                "semantic.choice.title.investigate",
                value: "Investigate"
            )
        case .localizedLabel:
            labelResolution?.title ?? semanticLocalized(
                "semantic.choice.title.unavailable",
                value: "Unavailable action"
            )
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
        case .useAbility:
            semanticLocalized(
                "semantic.choice.title.useAbility",
                value: "Use ability"
            )
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

    // swiftlint:disable:next function_body_length
    private func semanticUnavailableAnnouncement(
        for descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        if descriptor.kind == .localizedLabel {
            return labelResolution?.announcement
                ?? semanticLocalized(
                    "semantic.choice.unavailable.text",
                    value: "The text for this choice is not currently available."
                )
        }
        switch descriptor.kind {
        case .advanceAct:
            return semanticLocalized(
                "semantic.choice.unavailable.advanceAct",
                value:
                "The act or investigator for this choice is not currently available."
            )
        case .advanceAgenda:
            return semanticLocalized(
                "semantic.choice.unavailable.advanceAgenda",
                value:
                "The agenda or investigator for this choice is not currently available."
            )
        case .fight, .evade, .engage:
            return semanticLocalized(
                "semantic.choice.unavailable.enemy",
                value:
                "The enemy or investigator for this choice is not currently available."
            )
        case .investigate:
            return semanticLocalized(
                "semantic.choice.unavailable.location",
                value:
                "The location or investigator for this choice is not currently available."
            )
        case .chooseTarget:
            return semanticLocalized(
                "semantic.choice.unavailable.target",
                value: "The target for this choice is not currently available."
            )
        case .drawCard, .endTurn, .gainResource, .skipTriggers, .startSkillTest, .useAbility:
            return semanticLocalized(
                "semantic.choice.unavailable.investigator",
                value:
                "The investigator for this choice is not currently available."
            )
        case .applySkillTestResults:
            return semanticLocalized(
                "semantic.choice.unavailable.generic",
                value: "This choice is not currently available."
            )
        case .localizedLabel:
            return semanticLocalized(
                "semantic.choice.unavailable.text",
                value: "The text for this choice is not currently available."
            )
        }
    }

    func semanticLocalized(
        _ key: StaticString,
        value: String.LocalizationValue
    ) -> String {
        let locale = semanticLocaleIdentifier.map(Locale.init(identifier:)) ?? .current
        return String(
            localized: key,
            defaultValue: value,
            bundle: semanticLocalizationBundle,
            locale: locale
        )
    }

    private var semanticLocalizationBundle: Bundle {
        guard let semanticLocaleIdentifier else { return .module }
        let localization = Bundle.preferredLocalizations(
            from: Bundle.module.localizations,
            forPreferences: [semanticLocaleIdentifier, "en"]
        ).first
        guard let localization,
              let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .module }
        return bundle
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
