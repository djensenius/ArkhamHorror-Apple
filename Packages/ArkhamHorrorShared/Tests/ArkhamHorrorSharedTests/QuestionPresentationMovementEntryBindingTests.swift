@testable import ArkhamHorrorShared
import Foundation
import Testing

private let movementEntryHallwayFixtureID =
    "fda9afef-4166-4c9f-962e-eed6e8cbee25"

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
            with: .string("dbaa2d2e-4ceb-44b2-a554-e5fa370e7882")
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
            with: .string("dbaa2d2e-4ceb-44b2-a554-e5fa370e7882")
        )
        assertBindingFails(
            presentation: cellarDamage,
            rawQuestion: driftedAssignment,
            questionVersion: 38
        )
    }

    @Test("Q39 binds both branches and rejects raw or presentation ID drift")
    func gatheringPostEntryBinding() throws {
        let branches = [
            (
                movementIndex: 9,
                cardCode: "c01114",
                locationID: "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
            ),
            (
                movementIndex: 10,
                cardCode: "c01113",
                locationID: "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
            ),
        ]
        for branch in branches {
            try assertPostEntryBinding(
                movementIndex: branch.movementIndex,
                cardCode: branch.cardCode,
                locationID: branch.locationID
            )
        }
    }

    private func assertPostEntryBinding(
        movementIndex: Int,
        cardCode: String,
        locationID: String
    ) throws {
        let rawQuestion = try postEntryRawQuestion(
            movementIndex: movementIndex,
            cardCode: cardCode,
            locationID: locationID
        )
        let presentation = try postEntryPresentation(
            cardCode: cardCode,
            locationID: locationID,
            hallwayID: movementEntryHallwayFixtureID
        )
        let binding = try presentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: 39
        )
        #expect(
            binding.descriptor(forSourceIndex: 9)?.entity?.id == locationID
        )
        #expect(
            binding.descriptor(forSourceIndex: 10)?.entity?.id ==
                movementEntryHallwayFixtureID
        )

        let driftedRaw = try replacing(
            rawQuestion,
            at: "/choices/10/ability/source/contents",
            with: .string(locationID)
        )
        assertBindingFails(
            presentation: presentation,
            rawQuestion: driftedRaw,
            questionVersion: 39
        )

        let driftedPresentation = try postEntryPresentation(
            cardCode: cardCode,
            locationID: locationID,
            hallwayID: "33333333-3333-4333-8333-333333333333"
        )
        assertBindingFails(
            presentation: driftedPresentation,
            rawQuestion: rawQuestion,
            questionVersion: 39
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

    private func postEntryPresentation(
        cardCode: String,
        locationID: String,
        hallwayID: String
    ) throws -> QuestionPresentation {
        let movement = try presentationFixture(
            "question-presentation-gathering-movement"
        )
        let choices = Array(movement.choices.prefix(9)) + [
            .gatheringInvestigation(
                cardCode: cardCode,
                locationID: locationID
            ),
            .gatheringHallwayMovement(locationID: hallwayID),
        ]
        return try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(
                QuestionPresentation(
                    protocolVersion: 1,
                    questionVersion: 39,
                    questionKind: .playerWindowChooseOne,
                    choiceCount: choices.count,
                    choices: choices
                )
            )
        )
    }

    private func postEntryRawQuestion(
        movementIndex: Int,
        cardCode: String,
        locationID: String
    ) throws -> JSONValue {
        guard case var .object(root) =
            try rawFixture("question-gathering-movement"),
            case let .array(movementChoices)? = root["choices"],
            movementChoices.indices.contains(11),
            movementChoices.indices.contains(movementIndex)
        else {
            throw MovementEntryBindingFixtureError.unexpectedShape
        }
        let investigation = replacingStrings(
            in: movementChoices[11],
            replacements: [
                movementEntryHallwayFixtureID: locationID,
                "c01112": cardCode,
            ]
        )
        let movement = replacingStrings(
            in: movementChoices[movementIndex],
            replacements: [
                locationID: movementEntryHallwayFixtureID,
                cardCode: "c01112",
            ]
        )
        let hallwayMovement = try replacing(
            movement,
            at: "/ability/type/cost",
            with: .object([
                "contents": .number(.integer(1)),
                "tag": .string("ActionCost"),
            ])
        )
        root["choices"] = .array(
            Array(movementChoices.prefix(9)) + [
                investigation,
                hallwayMovement,
            ]
        )
        return .object(root)
    }

    private func replacingStrings(
        in value: JSONValue,
        replacements: [String: String]
    ) -> JSONValue {
        switch value {
        case let .string(string):
            .string(replacements[string] ?? string)
        case let .array(values):
            .array(values.map {
                replacingStrings(in: $0, replacements: replacements)
            })
        case let .object(object):
            .object(object.mapValues {
                replacingStrings(in: $0, replacements: replacements)
            })
        case .null, .bool, .number:
            value
        }
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

private enum MovementEntryBindingFixtureError: Error {
    case unexpectedShape
}
