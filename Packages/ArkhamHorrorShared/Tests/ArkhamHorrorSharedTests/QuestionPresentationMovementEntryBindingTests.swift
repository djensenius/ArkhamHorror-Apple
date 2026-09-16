@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Semantic movement-entry raw binding")
struct MovementEntryQuestionBindingTests {
    @Test("Q36-Q38 reject raw source drift and cross-branch presentation")
    func gatheringRawPresentationDriftFailsClosed() throws {
        let movement = try presentationFixture(
            "question-presentation-gathering-movement"
        )
        let driftedMovement = try replacing(
            rawFixture("question-gathering-movement"),
            at: "/choices/9/ability/source/contents",
            with: .string(QuestionPresentation.Choice.gatheringAtticLocationID)
        )
        assertBindingFails(
            presentation: movement,
            rawQuestion: driftedMovement,
            questionVersion: 36
        )

        let cellarForced = try presentationFixture(
            "question-presentation-gathering-cellar-entry-forced"
        )
        let atticForcedRaw = try rawFixture(
            "question-gathering-attic-entry-forced"
        )
        assertBindingFails(
            presentation: cellarForced,
            rawQuestion: atticForcedRaw,
            questionVersion: 37
        )

        let cellarDamage = try presentationFixture(
            "question-presentation-gathering-cellar-damage-assignment"
        )
        let atticHorrorRaw = try rawFixture(
            "question-gathering-attic-horror-assignment"
        )
        assertBindingFails(
            presentation: cellarDamage,
            rawQuestion: atticHorrorRaw,
            questionVersion: 38
        )

        let driftedAssignment = try replacing(
            rawFixture("question-gathering-cellar-damage-assignment"),
            at: "/source/contents/0/contents",
            with: .string(QuestionPresentation.Choice.gatheringAtticLocationID)
        )
        assertBindingFails(
            presentation: cellarDamage,
            rawQuestion: driftedAssignment,
            questionVersion: 38
        )
    }

    private func assertBindingFails(
        presentation: QuestionPresentation,
        rawQuestion: JSONValue,
        questionVersion: Int
    ) {
        #expect(throws: QuestionPresentationBindingError.self) {
            try presentation.bind(
                to: rawQuestion,
                expectedQuestionVersion: questionVersion
            )
        }
    }

    private func presentationFixture(
        _ name: String
    ) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    private func rawFixture(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixture(name))
    }

    private func replacing(
        _ value: JSONValue,
        at pointer: String,
        with replacement: JSONValue
    ) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: "replace",
            path: pointer.split(separator: "/"),
            replacement: replacement,
            to: value
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}
