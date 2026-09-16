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
            try missingHallway.validatePostEntryPrompt(
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
            try q39PromptEvidence(destination: destination)
                .validatePostEntryPrompt(destination: mismatchedDestination)
        }
    }

    private func q39PromptEvidence(
        destination: GatheringMovementEntryDestination,
        actionableSourceIndices: [Int] = Array(0 ..< 11)
    ) -> GatheringActReplayPromptEvidence {
        GatheringActReplayPromptEvidence(
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
            canonicalSHA256: destination.branch.q39PromptSHA256,
            selectedDescriptor: nil,
            governedDescriptors: [
                GatheringActReplayDescriptorEvidence(
                    choice: .gatheringInvestigation(
                        cardCode: destination.branch.locationCardCode,
                        locationID:
                        destination.locationID.codingKey.stringValue
                    )
                ),
                GatheringActReplayDescriptorEvidence(
                    choice: .gatheringHallwayMovement(
                        locationID:
                        "fda9afef-4166-4c9f-962e-eed6e8cbee25"
                    )
                ),
            ]
        )
    }
}
