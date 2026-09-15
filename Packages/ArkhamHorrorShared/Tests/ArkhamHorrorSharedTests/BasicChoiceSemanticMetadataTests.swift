@testable import ArkhamHorrorShared
import Testing

extension BasicChoiceSemanticPresentationTests {
    @Test("Semantic localized labels use catalog resolution and fail closed")
    func localizedLabelUsesSemanticSourceIndex() throws {
        let projection = gatheringProjection(includeAct: false, includeInvestigator: false)
        let unavailable = try semanticPrompt(
            choice: localizedLabelChoice,
            choiceLabelResolutions: [0: .unavailable(.missingKey)]
        )
        let unavailableChoice = try #require(unavailable.choices.first)
        #expect(!unavailable.isChoiceActionable(unavailableChoice, in: projection))
        #expect(
            unavailable.displayTitle(for: unavailableChoice, in: projection)
                == "Unavailable action"
        )
        #expect(
            unavailable.accessibilityHint(for: unavailableChoice, in: projection)
                == "This server publishes no usable text for this choice."
        )

        let resolved = try semanticPrompt(
            choice: localizedLabelChoice,
            choiceLabelResolutions: [0: .resolved("Continue")]
        )
        let resolvedChoice = try #require(resolved.choices.first)
        #expect(resolved.displayTitle(for: resolvedChoice, in: projection) == "Continue")
        #expect(resolved.isChoiceActionable(resolvedChoice, in: projection))
        #expect(
            resolved.accessibilityHint(for: resolvedChoice, in: projection)
                == "Activates choice 1."
        )
    }

    @Test("Recursive semantic costs preserve grouping but never decide actionability")
    func recursiveCostsAreDisplayOnly() throws {
        let prompt = try semanticPrompt(choice: recursiveCostChoice)
        let projection = gatheringProjection(includeAct: false, includeInvestigator: true)
        let choice = try #require(prompt.choices.first)
        let expectedTitle = "Use ability (1 action and "
            + "(2 resources or 1 resource + 2 resources per investigator at the same location) "
            + "and 1/2/3/4 clues by player count and X clues and ★ clues "
            + "and an unknown number of clues and additional cost)"

        #expect(projection.investigators.first?.tokenCounts.isEmpty == true)
        #expect(prompt.displayTitle(for: choice, in: projection) == expectedTitle)
        #expect(prompt.isChoiceActionable(choice, in: projection))
    }

    private var localizedLabelChoice: QuestionPresentation.Choice {
        .init(
            sourceIndex: 0,
            kind: .localizedLabel,
            actorID: nil,
            entity: nil,
            label: .init(kind: .embeddedI18n, text: "$continue"),
            ability: nil,
            cost: nil
        )
    }

    private var recursiveCostChoice: QuestionPresentation.Choice {
        .init(
            sourceIndex: 0,
            kind: .useAbility,
            actorID: "c01001",
            entity: nil,
            label: nil,
            ability: .init(
                cardCode: "c01001",
                index: 1,
                type: .action,
                actions: [.activate],
                canBeCancelled: true
            ),
            cost: .all([
                .action(1),
                .choice([
                    .resource(2),
                    .groupResource(
                        amount: .fixedPlusPerPlayer(fixed: 1, perPlayer: 2),
                        scope: .sameLocation
                    ),
                ]),
                .clue(.byPlayerCount([1, 2, 3, 4])),
                .clue(.variable),
                .clue(.star),
                .clue(.unknown),
                .other,
            ])
        )
    }

    private func semanticPrompt(
        choice: QuestionPresentation.Choice,
        choiceLabelResolutions: [Int: BasicChoiceLabelResolution]? = nil
    ) throws -> BasicChoicePromptPresentation {
        let payload = try rawPayload("question-gathering-act-advance")
        let presentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 35,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [choice]
        )
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: 35
        )
        return makePrompt(
            payload: payload,
            presentation: bound,
            choiceLabelResolutions: choiceLabelResolutions
        )
    }
}
