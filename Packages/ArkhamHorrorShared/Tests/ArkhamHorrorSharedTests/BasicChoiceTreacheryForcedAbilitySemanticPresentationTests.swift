@testable import ArkhamHorrorShared
import Foundation
import Testing

extension BasicChoiceSemanticPresentationTests {
    @Test("Treachery forced abilities render, focus, and submit their exact source index")
    func treacheryForcedAbilityUsesGenericPath() throws {
        let prompt = try prompt(
            rawFixture: "question-treachery-forced-ability",
            presentationFixture: "question-presentation-treachery-forced-ability"
        )
        let projection = treacheryForcedAbilityProjection()
        let choice = try #require(prompt.choices.first)

        #expect(
            prompt.displayTitle(for: choice, in: projection)
                == "Resolve forced ability (free)"
        )
        #expect(
            prompt.systemImage(for: choice)
                == "exclamationmark.triangle.fill"
        )
        #expect(prompt.isChoiceActionable(choice, in: projection))

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(
            controller.coordinator.currentFocus
                == BoardFocusID.promptChoice(0)
        )
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])
    }

    @Test("Treachery forced abilities in non-window prompts are not actionable when unsealed")
    func treacheryForcedAbilityInChooseOneRequiresSeal() throws {
        var raw = try fixtureJSON("question-treachery-forced-ability")
        guard case var .object(rawObject) = raw else {
            throw TreacheryFixtureError.unexpectedShape
        }
        rawObject["tag"] = .string("ChooseOne")
        raw = .object(rawObject)
        let treacheryChoice = try treacheryPresentationChoice(sourceIndex: 0)
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 68,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [treacheryChoice]
        )
        let binding = try presentation.bind(to: raw, expectedQuestionVersion: 68)
        let prompt = makePrompt(
            payload: BasicChoiceQuestionPayload(
                rawValue: raw,
                state: BasicChoiceParser.parseQuestion(raw)
            ),
            presentation: binding
        )
        let choice = try #require(prompt.choices.first)

        #expect(binding.presentation.sealValidationKind == .treacheryForcedAbility)
        #expect(!binding.usesSealedActionabilityOverlay)
        #expect(!prompt.isChoiceActionable(choice, in: treacheryForcedAbilityProjection()))
    }

    @Test("A neighbouring move cannot make an unsealed treachery prompt actionable")
    func treacheryForcedAbilityNextToMoveRequiresSeal() throws {
        let treacheryRaw = try treacheryRawChoice()
        let moveRaw = try gatheringMovementRawChoice()
        let raw: JSONValue = .object([
            "tag": .string("PlayerWindowChooseOne"),
            "choices": .array([treacheryRaw, moveRaw]),
        ])
        let presentation = try QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 68,
            questionKind: .playerWindowChooseOne,
            choiceCount: 2,
            choices: [
                treacheryPresentationChoice(sourceIndex: 0),
                .gatheringMovement(
                    sourceIndex: 1,
                    cardCode: "c01114",
                    locationID: "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
                ),
            ]
        )
        let binding = try presentation.bind(to: raw, expectedQuestionVersion: 68)
        let prompt = makePrompt(
            payload: BasicChoiceQuestionPayload(
                rawValue: raw,
                state: BasicChoiceParser.parseQuestion(raw)
            ),
            presentation: binding
        )
        let projection = treacheryForcedAbilityProjection()

        #expect(binding.presentation.sealValidationKind == .treacheryForcedAbility)
        #expect(!binding.usesSealedActionabilityOverlay)
        #expect(prompt.choices.allSatisfy { !prompt.isChoiceActionable($0, in: projection) })
    }

    @Test("Treachery forced abilities require current matching board identities")
    func treacheryForcedAbilityRevalidatesProjection() throws {
        let prompt = try prompt(
            rawFixture: "question-treachery-forced-ability",
            presentationFixture: "question-presentation-treachery-forced-ability"
        )
        let choice = try #require(prompt.choices.first)

        #expect(!prompt.isChoiceActionable(
            choice,
            in: treacheryForcedAbilityProjection(includeTreachery: false)
        ))
        #expect(!prompt.isChoiceActionable(
            choice,
            in: treacheryForcedAbilityProjection(
                treacheryCardCode: "c01165"
            )
        ))
        #expect(!prompt.isChoiceActionable(
            choice,
            in: treacheryForcedAbilityProjection(includeInvestigator: false)
        ))
    }

    func treacheryForcedAbilityProjection(
        includeTreachery: Bool = true,
        treacheryCardCode: String = "c01007",
        includeInvestigator: Bool = true
    ) -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let treacheryID = exactTreacheryID(treacheryForcedAbilityFixtureID)
        let treacheries: [TreacheryID: JSONValue] = includeTreachery
            ? [
                treacheryID: .object([
                    "id": .string(treacheryForcedAbilityFixtureID),
                    "cardCode": .string(treacheryCardCode),
                    "tokens": .array([]),
                ]),
            ]
            : [:]
        return BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                investigators: includeInvestigator
                    ? [
                        investigatorID:
                            BoardTestFixtures.investigator(id: investigatorID),
                    ]
                    : [:],
                activeInvestigatorID: investigatorID,
                leadInvestigatorID: investigatorID,
                treacheryValues: treacheries
            )
        )
    }

    private func treacheryPresentationChoice(
        sourceIndex: Int
    ) throws -> QuestionPresentation.Choice {
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: fixtureData("question-presentation-treachery-forced-ability")
        )
        return try #require(presentation.choices.first).replacingSourceIndex(sourceIndex)
    }

    private func treacheryRawChoice() throws -> JSONValue {
        guard case let .object(root) = try fixtureJSON("question-treachery-forced-ability"),
              case let .array(choices)? = root["choices"],
              let choice = choices.first
        else { throw TreacheryFixtureError.unexpectedShape }
        return choice
    }

    private func gatheringMovementRawChoice() throws -> JSONValue {
        guard case let .object(root) = try fixtureJSON("question-gathering-movement"),
              case let .array(choices)? = root["choices"],
              choices.indices.contains(9)
        else { throw TreacheryFixtureError.unexpectedShape }
        return choices[9]
    }

    private func fixtureJSON(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    private func exactTreacheryID(_ raw: String) -> TreacheryID {
        // swiftlint:disable:next force_unwrapping
        TreacheryID(UUID(uuidString: raw)!)
    }
}

private enum TreacheryFixtureError: Error {
    case unexpectedShape
}
