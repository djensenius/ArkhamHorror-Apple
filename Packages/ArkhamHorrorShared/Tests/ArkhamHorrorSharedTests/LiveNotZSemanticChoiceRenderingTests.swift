@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Live NotZ semantic choice rendering")
struct LiveNotZSemanticChoiceRenderingTests {
    @Test("Captured semantic choices render through the prompt presentation path")
    func capturedSemanticChoicesRenderThroughPromptPresentationPath() throws {
        let samples = try Self.renderingSamples()
        #expect(Set(samples.map(\.kind)) == [
            "advanceAgenda",
            "assignDamage",
            "assignHorror",
            "chooseTarget",
            "componentLabel",
            "localizedLabel",
            "move",
            "resolveForcedAbility",
            "useAbility",
        ])
        let projection = try Self.capturedProjection()

        for sample in samples {
            let prompt = try Self.prompt(for: sample)
            let choice = try #require(
                prompt.choices.first { $0.index == sample.source.choiceIndex },
                "\(sample.kind) captured choice is present"
            )
            let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

            #expect(prompt.isRenderableQuestion, "\(sample.kind) prompt is renderable")
            #expect(prompt.canSubmit, "\(sample.kind) prompt remains submittable")
            #expect(
                prompt.displayOrderedChoices().map(\.index).contains(choice.index),
                "\(sample.kind) captured choice is displayed"
            )
            #expect(
                prompt.isChoiceActionable(choice, in: projection),
                "\(sample.kind) captured choice is actionable"
            )
            #expect(
                choice.title == "Update required",
                Comment(rawValue:
                    "\(sample.kind) preserves the legacy raw-choice diagnostic that caused the "
                        + "round-3 harness misclassification")
            )
            #expect(
                resolved.title == sample.expectedTitle,
                "\(sample.kind) BasicChoicePromptView title comes from the semantic presentation"
            )
            #expect(resolved.title != "Update required", "\(sample.kind) does not render Update required")
            #expect(
                resolved.systemImage == sample.expectedSystemImage,
                "\(sample.kind) uses the semantic icon rendered by BasicChoicePromptView"
            )
            #expect(
                prompt.accessibilityHint(for: choice, in: projection)
                    == "Activates choice \(choice.index + 1).",
                "\(sample.kind) keeps single-choice actionability semantics"
            )
        }
    }

    @Test("Unresolved captured catalog labels remain visible but not pressable")
    func unresolvedCapturedCatalogLabelsRemainUnpressable() throws {
        let sample = try #require(
            Self.renderingSamples().first { $0.kind == "localizedLabel" }
        )
        let prompt = try Self.prompt(
            for: sample,
            choiceLabelResolutions: [0: .unavailable(.catalog(.notAdvertised))]
        )
        let projection = try Self.capturedProjection()
        let choice = try #require(prompt.choices.first { $0.index == sample.source.choiceIndex })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Choice 1")
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(
            prompt.accessibilityHint(for: choice, in: projection)
                == "The text for this choice is unavailable from this server."
        )
    }

    private static func prompt(
        for sample: RenderingSample,
        choiceLabelResolutions overrideResolutions: [Int: BasicChoiceLabelResolution]? = nil
    ) throws -> BasicChoicePromptPresentation {
        let bound = try sample.questionPresentation.bind(
            to: sample.rawQuestion,
            expectedQuestionVersion: sample.source.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: sample.source.questionVersion,
                rawQuestion: sample.rawQuestion,
                questionPresentation: sample.questionPresentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(sample.rawQuestion),
            semanticPresentation: bound,
            semanticLocaleIdentifier: "en",
            cardCatalog: try capturedCardCatalog(),
            choiceLabelResolutions: overrideResolutions ?? sample.choiceLabelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func renderingSamples() throws -> [RenderingSample] {
        let url = try #require(Bundle.module.url(
            forResource: "render-choice-kind-samples",
            withExtension: "json",
            subdirectory: "Fixtures/LiveNightOfTheZealotPlaythrough"
        ))
        let fixture = try ContractJSON.decode(RenderingSamplesFixture.self, from: Data(
            contentsOf: url
        ))
        return fixture.samples
    }

    private static func capturedProjection() throws -> BoardProjection {
        let agnesID = BoardTestFixtures.investigatorID("c01004")
        let wendyID = BoardTestFixtures.investigatorID("c01005")
        let locationID = try semanticLocationID("01581c53-86ca-4a88-a192-ab1a2d2775e0")
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID,
                    label: "Captured location"
                ))
            )],
            investigators: [
                agnesID: BoardTestFixtures.investigator(
                    id: agnesID,
                    name: CardName(title: "Captured investigator", subtitle: nil),
                    playerID: BoardTestFixtures.playerID("000000000001")
                ),
                wendyID: BoardTestFixtures.investigator(
                    id: wendyID,
                    name: CardName(title: "Captured mover", subtitle: nil),
                    playerID: BoardTestFixtures.playerID("000000000002")
                ),
            ],
            playerOrder: [agnesID, wendyID]
        ))
    }

    private static func capturedCardCatalog() throws -> CardCatalogSnapshot {
        try CardCatalogSnapshot(namesByCode: [
            CardCode("c01013"): CardName(title: "Captured ability card", subtitle: nil),
            CardCode("c01164"): CardName(title: "Captured treachery", subtitle: nil),
        ])
    }

    private static func semanticLocationID(_ raw: String) throws -> LocationID {
        try #require(LocationID(codingKey: AnyCodingKey(stringValue: raw)))
    }
}

private struct RenderingSamplesFixture: Decodable, Sendable {
    let samples: [RenderingSample]
}

private struct RenderingSample: Decodable, Sendable {
    let kind: String
    let source: RenderingSampleSource
    let expectedTitle: String
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation

    var expectedSystemImage: String {
        switch kind {
        case "advanceAgenda": "arrow.up.circle.fill"
        case "assignDamage": "heart.slash.fill"
        case "assignHorror": "brain.head.profile.fill"
        case "chooseTarget": "scope"
        case "componentLabel": "circle.grid.cross"
        case "localizedLabel": "text.bubble.fill"
        case "move": "figure.walk"
        case "resolveForcedAbility": "exclamationmark.triangle.fill"
        case "useAbility": "bolt.circle.fill"
        default: "questionmark.square.dashed"
        }
    }

    var choiceLabelResolutions: [Int: BasicChoiceLabelResolution] {
        Dictionary(uniqueKeysWithValues: questionPresentation.choices.compactMap { choice in
            guard choice.label?.text == "$continue" else { return nil }
            return (choice.sourceIndex, .resolved("Continue"))
        })
    }
}

private struct RenderingSampleSource: Decodable, Sendable {
    let questionVersion: Int
    let choiceIndex: Int
}
