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

    private func exactTreacheryID(_ raw: String) -> TreacheryID {
        // swiftlint:disable:next force_unwrapping
        TreacheryID(UUID(uuidString: raw)!)
    }
}
