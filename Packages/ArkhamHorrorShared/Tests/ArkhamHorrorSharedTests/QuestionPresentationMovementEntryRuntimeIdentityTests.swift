@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Semantic movement-entry runtime identity")
struct MovementEntryRuntimeIdentityTests {
    private let cellarFixtureID =
        "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
    private let atticFixtureID =
        "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
    private let remappedCellarID =
        "11111111-1111-4111-8111-111111111111"
    private let remappedAtticID =
        "22222222-2222-4222-8222-222222222222"

    @Test("Q36 binds consistently remapped movement locations")
    func gatheringMovementRemappingBinds() throws {
        let replacements = [
            cellarFixtureID: remappedCellarID,
            atticFixtureID: remappedAtticID,
        ]
        let presentation = try remappedPresentation(
            "question-presentation-gathering-movement",
            replacements: replacements
        )
        let binding = try presentation.bind(
            to: remappedRawQuestion(
                "question-gathering-movement",
                replacements: replacements
            ),
            expectedQuestionVersion: 36
        )

        #expect(
            binding.descriptor(forSourceIndex: 9)?.entity?.id ==
                remappedCellarID
        )
        #expect(
            binding.descriptor(forSourceIndex: 10)?.entity?.id ==
                remappedAtticID
        )
    }

    @Test("Q37 binds a consistently remapped forced location")
    func gatheringForcedAbilityRemappingBinds() throws {
        let replacements = [cellarFixtureID: remappedCellarID]
        let presentation = try remappedPresentation(
            "question-presentation-gathering-cellar-entry-forced",
            replacements: replacements
        )
        let binding = try presentation.bind(
            to: remappedRawQuestion(
                "question-gathering-cellar-entry-forced",
                replacements: replacements
            ),
            expectedQuestionVersion: 37
        )

        #expect(
            binding.descriptor(forSourceIndex: 0)?.entity?.id ==
                remappedCellarID
        )
    }

    @Test("Q38 preserves a remapped governed source location")
    func gatheringAssignmentRemappingBinds() throws {
        let presentation = try presentationFixture(
            "question-presentation-gathering-cellar-damage-assignment"
        )
        let binding = try presentation.bind(
            to: remappedRawQuestion(
                "question-gathering-cellar-damage-assignment",
                replacements: [cellarFixtureID: remappedCellarID]
            ),
            expectedQuestionVersion: 38
        )

        #expect(
            binding.governedSource ==
                .init(
                    entity: .init(
                        kind: .location,
                        id: remappedCellarID
                    ),
                    cardCode: "c01114"
                )
        )
    }

    @Test("Q39 accepts a runtime Hallway identity and rejects semantic drift")
    func gatheringPostEntryMovementBinds() throws {
        let hallwayID = "33333333-3333-4333-8333-333333333333"
        let presentation = try postEntryPresentation(hallwayID: hallwayID)
        #expect(presentation.choiceCount == 11)
        #expect(presentation.choices.last?.entity?.id == hallwayID)

        let drifted = try replacing(
            presentation,
            choiceIndex: 10,
            abilityCardCode: "c01113"
        )
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: drifted
            )
        }
    }

    private func postEntryPresentation(
        hallwayID: String
    ) throws -> QuestionPresentation {
        let movement = try presentationFixture(
            "question-presentation-gathering-movement"
        )
        let choices = Array(movement.choices.prefix(9)) + [
            postEntryInvestigateChoice(),
            .gatheringHallwayMovement(locationID: hallwayID),
        ]
        let presentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 39,
            questionKind: .playerWindowChooseOne,
            choiceCount: choices.count,
            choices: choices
        )
        return try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(presentation)
        )
    }

    private func postEntryInvestigateChoice() -> QuestionPresentation.Choice {
        .gatheringInvestigation(
            cardCode: "c01114",
            locationID: remappedCellarID
        )
    }

    private func replacing(
        _ presentation: QuestionPresentation,
        choiceIndex: Int,
        abilityCardCode: String
    ) throws -> Data {
        guard case var .object(root) = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(presentation)
        ),
            case var .array(choices)? = root["choices"],
            choices.indices.contains(choiceIndex),
            case var .object(choice) = choices[choiceIndex],
            case var .object(ability)? = choice["ability"]
        else {
            throw RuntimeIdentityFixtureError.unexpectedShape
        }
        ability["cardCode"] = .string(abilityCardCode)
        choice["ability"] = .object(ability)
        choices[choiceIndex] = .object(choice)
        root["choices"] = .array(choices)
        return try ContractJSON.encode(JSONValue.object(root))
    }

    private func remappedPresentation(
        _ name: String,
        replacements: [String: String]
    ) throws -> QuestionPresentation {
        try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(
                replacingStrings(
                    in: rawFixture(name),
                    replacements: replacements
                )
            )
        )
    }

    private func remappedRawQuestion(
        _ name: String,
        replacements: [String: String]
    ) throws -> JSONValue {
        try replacingStrings(
            in: rawFixture(name),
            replacements: replacements
        )
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

    private func presentationFixture(
        _ name: String
    ) throws -> QuestionPresentation {
        try ContractJSON.decode(
            QuestionPresentation.self,
            from: fixture(name)
        )
    }

    private func rawFixture(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixture(name))
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

    private enum RuntimeIdentityFixtureError: Error {
        case unexpectedShape
    }
}
