import Foundation

extension BasicChoicePromptPresentation {
    var isRenderableQuestion: Bool {
        if let semanticPresentation {
            return semanticPresentation.presentation.questionKind != .unsupported
                && !semanticPresentation.rawChoices.isEmpty
        }
        return question.supportedQuestion?.choices.isEmpty == false
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
                value: "Unavailable action (choice \(choice.index + 1))",
                arguments: [Int64(choice.index + 1)]
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
            value: "\(title) (\(costSummary))",
            arguments: [title, costSummary]
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
        case .assignDamage: "heart.slash.fill"
        case .assignHorror: "brain.head.profile.fill"
        case .chooseTarget: "scope"
        case .drawCard: "rectangle.stack"
        case .endTurn: "forward.end"
        case .engage: "person.2.fill"
        case .evade: "figure.run"
        case .fight: "burst.fill"
        case .gainResource: "circle.fill"
        case .investigate: "magnifyingglass"
        case .localizedLabel: "text.bubble.fill"
        case .move: "figure.walk"
        case .resolveForcedAbility: "exclamationmark.triangle.fill"
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
            value: "Activates choice \(choice.index + 1).",
            arguments: [Int64(choice.index + 1)]
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
        case .chooseTarget:
            descriptor.entity.flatMap { semanticEntityTitle($0, in: projection) }
                .map {
                    semanticLocalized(
                        "semantic.choice.title.chooseEntity",
                        value: "Choose \($0)",
                        arguments: [$0]
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
