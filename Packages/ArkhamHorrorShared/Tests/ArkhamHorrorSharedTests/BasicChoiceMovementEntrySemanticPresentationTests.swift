@testable import ArkhamHorrorShared
import Foundation
import Testing

extension BasicChoiceSemanticPresentationTests {
    @Test("Q36 renders, focuses, and submits exact Cellar and Attic movement indices")
    func q36MovementUsesGenericPath() throws {
        let prompt = try prompt(
            rawFixture: "question-gathering-movement",
            presentationFixture: "question-presentation-gathering-movement"
        )
        let projection = gatheringMovementProjection()
        let cellar = try #require(prompt.choices.first { $0.index == 9 })
        let attic = try #require(prompt.choices.first { $0.index == 10 })

        #expect(
            prompt.displayTitle(for: cellar, in: projection)
                == "Move to Cellar (1 action and additional cost)"
        )
        #expect(
            prompt.displayTitle(for: attic, in: projection)
                == "Move to Attic (1 action and additional cost)"
        )
        #expect(prompt.systemImage(for: cellar) == "figure.walk")
        #expect(prompt.systemImage(for: attic) == "figure.walk")
        #expect(prompt.isChoiceActionable(cellar, in: projection))
        #expect(prompt.isChoiceActionable(attic, in: projection))
        #expect(
            prompt.accessibilityHint(for: cellar, in: projection)
                == "Activates choice 10."
        )

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        let actionableSourceIndices = prompt.choices.compactMap {
            prompt.isChoiceActionable($0, in: projection) ? $0.index : nil
        }
        for sourceIndex in actionableSourceIndices.dropFirst() {
            #expect(controller.handle(.command(.focusMove(.down))))
            #expect(
                controller.coordinator.currentFocus
                    == BoardFocusID.promptChoice(sourceIndex)
            )
        }
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(10))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [10])

        let withoutCellar = gatheringMovementProjection(includeCellar: false)
        #expect(!prompt.isChoiceActionable(cellar, in: withoutCellar))
        #expect(prompt.isChoiceActionable(attic, in: withoutCellar))
        #expect(
            prompt.accessibilityHint(for: cellar, in: withoutCellar)
                == "The location or investigator for this choice is not currently available."
        )
    }

    @Test("Q37 renders mandatory Cellar and Attic forced abilities")
    func q37ForcedAbilitiesUseGenericPath() throws {
        let projection = gatheringMovementProjection()
        let cellarPrompt = try prompt(
            rawFixture: "question-gathering-cellar-entry-forced",
            presentationFixture: "question-presentation-gathering-cellar-entry-forced"
        )
        let cellar = try #require(cellarPrompt.choices.first)
        #expect(
            cellarPrompt.displayTitle(for: cellar, in: projection)
                == "Resolve forced ability at Cellar (free)"
        )
        #expect(
            cellarPrompt.systemImage(for: cellar)
                == "exclamationmark.triangle.fill"
        )
        #expect(cellarPrompt.isChoiceActionable(cellar, in: projection))

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: cellarPrompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])

        let atticPrompt = try prompt(
            rawFixture: "question-gathering-attic-entry-forced",
            presentationFixture: "question-presentation-gathering-attic-entry-forced"
        )
        let attic = try #require(atticPrompt.choices.first)
        #expect(
            atticPrompt.displayTitle(for: attic, in: projection)
                == "Resolve forced ability at Attic (free)"
        )
        #expect(atticPrompt.isChoiceActionable(attic, in: projection))

        let withoutAttic = gatheringMovementProjection(includeAttic: false)
        #expect(!atticPrompt.isChoiceActionable(attic, in: withoutAttic))
        #expect(
            atticPrompt.accessibilityHint(for: attic, in: withoutAttic)
                == "The source or investigator for this forced ability is not currently available."
        )
    }

    @Test("Q38 renders and submits investigator damage and horror assignments")
    func q38AssignmentsUseGenericPath() throws {
        let projection = gatheringMovementProjection()
        let cellarPrompt = try prompt(
            rawFixture: "question-gathering-cellar-damage-assignment",
            presentationFixture: "question-presentation-gathering-cellar-damage-assignment"
        )
        let damage = try #require(cellarPrompt.choices.first)
        #expect(
            cellarPrompt.displayTitle(for: damage, in: projection)
                == "Assign damage to Test Investigator"
        )
        #expect(cellarPrompt.systemImage(for: damage) == "heart.slash.fill")
        #expect(cellarPrompt.isChoiceActionable(damage, in: projection))

        let atticPrompt = try prompt(
            rawFixture: "question-gathering-attic-horror-assignment",
            presentationFixture: "question-presentation-gathering-attic-horror-assignment"
        )
        let horror = try #require(atticPrompt.choices.first)
        #expect(
            atticPrompt.displayTitle(for: horror, in: projection)
                == "Assign horror to Test Investigator"
        )
        #expect(atticPrompt.systemImage(for: horror) == "brain.head.profile.fill")
        #expect(atticPrompt.isChoiceActionable(horror, in: projection))

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: atticPrompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.activatePromptChoice(0))
        #expect(submitted == [0])

        let withoutInvestigator = gatheringMovementProjection(
            includeInvestigator: false
        )
        #expect(!cellarPrompt.isChoiceActionable(damage, in: withoutInvestigator))
        #expect(!atticPrompt.isChoiceActionable(horror, in: withoutInvestigator))
        #expect(
            cellarPrompt.accessibilityHint(for: damage, in: withoutInvestigator)
                == "The investigator for this assignment is not currently available."
        )
    }

    private func gatheringMovementProjection(
        includeCellar: Bool = true,
        includeAttic: Bool = true,
        includeInvestigator: Bool = true
    ) -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let cellarID = exactLocationID(
            "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
        )
        let atticID = exactLocationID(
            "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
        )
        var locations: [(LocationID, Location)] = []
        if includeCellar {
            locations.append(
                (
                    cellarID,
                    .ordinary(
                        BoardTestFixtures.ordinaryLocation(
                            id: cellarID,
                            cardCode: BoardTestFixtures.cardCode("c01114"),
                            label: "Cellar"
                        )
                    )
                )
            )
        }
        if includeAttic {
            locations.append(
                (
                    atticID,
                    .ordinary(
                        BoardTestFixtures.ordinaryLocation(
                            id: atticID,
                            cardCode: BoardTestFixtures.cardCode("c01113"),
                            label: "Attic"
                        )
                    )
                )
            )
        }
        return BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                locations: locations,
                investigators: includeInvestigator
                    ? [investigatorID: BoardTestFixtures.investigator(id: investigatorID)]
                    : [:],
                activeInvestigatorID: investigatorID,
                leadInvestigatorID: investigatorID
            )
        )
    }

    private func exactLocationID(_ raw: String) -> LocationID {
        // swiftlint:disable:next force_unwrapping
        LocationID(UUID(uuidString: raw)!)
    }
}
