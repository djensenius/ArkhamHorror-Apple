@testable import ArkhamHorrorShared
import Testing

@Suite("Production Gathering post-entry evidence")
struct GatheringPostEntryEvidenceTests {
    @Test("Q39 requires Hallway actionability and Q36 destination")
    func identityAndActionability() throws {
        let locationID = try #require(
            LocationID(
                codingKey: AnyCodingKey(
                    stringValue:
                    "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
                )
            )
        )
        let destination = GatheringMovementEntryDestination(
            branch: .cellar,
            locationID: locationID
        )
        let missingHallway = q39PromptEvidence(
            destination: destination,
            actionableSourceIndices: Array(0 ..< 10)
        )
        #expect(
            throws: ProductionGatheringActReplayEvidenceError.invalidQ39
        ) {
            _ = try missingHallway.validatePostEntryPrompt(
                destination: destination
            )
        }

        let mismatchedLocationID = try #require(
            LocationID(
                codingKey: AnyCodingKey(
                    stringValue:
                    "11111111-1111-4111-8111-111111111111"
                )
            )
        )
        let mismatchedDestination = GatheringMovementEntryDestination(
            branch: .cellar,
            locationID: mismatchedLocationID
        )
        #expect(
            throws: ProductionGatheringActReplayEvidenceError.invalidQ39
        ) {
            _ = try q39PromptEvidence(destination: destination)
                .validatePostEntryPrompt(destination: mismatchedDestination)
        }
    }

    @Test("Q39 accepts both backend-observed semantic-role source orders")
    func sourceOrderVariants() throws {
        for branch in [
            GatheringMovementEntryBranch.cellar,
            .attic,
        ] {
            let locationID = try #require(
                LocationID(
                    codingKey: AnyCodingKey(
                        stringValue: branch == .cellar
                            ? "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
                            : "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
                    )
                )
            )
            let destination = GatheringMovementEntryDestination(
                branch: branch,
                locationID: locationID
            )
            let prompt = try q39PromptEvidence(
                destination: destination,
                investigationSourceIndex: 10,
                canonicalSHA256:
                #require(
                    branch.q39PromptSHA256s.first {
                        $0 != branch.q39PromptSHA256
                    }
                )
            )
            let validation = try prompt.validatePostEntryPrompt(
                destination: destination
            )
            #expect(
                validation.selectedSourceIndex ==
                    (branch == .cellar ? 10 : 9)
            )
        }
    }

    private func q39PromptEvidence(
        destination: GatheringMovementEntryDestination,
        actionableSourceIndices: [Int] = Array(0 ..< 11),
        investigationSourceIndex: Int = 9,
        canonicalSHA256: String? = nil
    ) -> GatheringActReplayPromptEvidence {
        let hallwayID =
            "fda9afef-4166-4c9f-962e-eed6e8cbee25"
        let hallwaySourceIndex =
            investigationSourceIndex == 9 ? 10 : 9
        let investigation = GatheringActReplayDescriptorEvidence(
            choice: .gatheringInvestigation(
                sourceIndex: investigationSourceIndex,
                cardCode: destination.branch.locationCardCode,
                locationID:
                destination.locationID.codingKey.stringValue
            )
        )
        let hallway = GatheringActReplayDescriptorEvidence(
            choice: .gatheringHallwayMovement(
                sourceIndex: hallwaySourceIndex,
                locationID: hallwayID
            )
        )
        return GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .postEntryQuestionVersion,
            rawTag:
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            questionKind:
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            choiceCount: 11,
            sourceIndices: Array(0 ..< 11),
            actionableSourceIndices: actionableSourceIndices,
            canonicalSHA256:
            canonicalSHA256 ?? destination.branch.q39PromptSHA256,
            selectedDescriptor:
            destination.branch == .cellar ? investigation : hallway,
            governedDescriptors: [investigation, hallway]
        )
    }
}
