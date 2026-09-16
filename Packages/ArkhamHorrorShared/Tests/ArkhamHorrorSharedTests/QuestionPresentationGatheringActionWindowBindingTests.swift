@testable import ArkhamHorrorShared
import Foundation
import Testing

private let q42HallwayFixtureID =
    "fda9afef-4166-4c9f-962e-eed6e8cbee25"
private let q42CellarFixtureID =
    "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
private let q42AtticFixtureID =
    "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"

private enum AtticQ42Role {
    case atticMovement
    case hallwayInvestigation
    case cellarMovement
}

@Suite("Semantic Gathering action-window raw binding")
struct GatheringActionWindowBindingTests {
    @Test("Attic Q42 seals every choice and canonicalizes location roles")
    func gatheringAtticQ42Binding() throws {
        let roleOrders: [[AtticQ42Role]] = [
            [
                .atticMovement,
                .hallwayInvestigation,
                .cellarMovement,
            ],
            [
                .cellarMovement,
                .hallwayInvestigation,
                .atticMovement,
            ],
        ]
        for roleOrder in roleOrders {
            let rawQuestion = try atticQ42RawQuestion(
                roleOrder: roleOrder
            )
            let presentation = try atticQ42Presentation(
                roleOrder: roleOrder
            )
            let binding = try presentation.bind(
                to: rawQuestion,
                expectedQuestionVersion: 42
            )
            #expect(binding.presentation.choices.count == 12)
        }

        let rawQuestion = try atticQ42RawQuestion(
            roleOrder: roleOrders[0]
        )
        let presentation = try atticQ42Presentation(
            roleOrder: roleOrders[0]
        )
        try assertRawTargetDriftFails(
            presentation: presentation,
            rawQuestion: rawQuestion
        )
        try assertPresentationTargetDriftFails(
            presentation: presentation,
            rawQuestion: rawQuestion
        )
        try assertMovementDowngradeFails(
            presentation: presentation,
            rawQuestion: rawQuestion
        )
    }

    private func assertRawTargetDriftFails(
        presentation: QuestionPresentation,
        rawQuestion: JSONValue
    ) throws {
        let driftedRaw = try replacing(
            rawQuestion,
            at: "/choices/2/target/contents",
            with:
            .string("33333333-3333-4333-8333-333333333333")
        )
        assertActionWindowBindingFails(
            presentation: presentation,
            rawQuestion: driftedRaw
        )
    }

    private func assertPresentationTargetDriftFails(
        presentation: QuestionPresentation,
        rawQuestion: JSONValue
    ) throws {
        var driftedChoices = presentation.choices
        let target = driftedChoices[2]
        driftedChoices[2] = QuestionPresentation.Choice(
            sourceIndex: target.sourceIndex,
            kind: target.kind,
            actorID: target.actorID,
            entity: .init(
                kind: .card,
                id: "33333333-3333-4333-8333-333333333333"
            ),
            label: target.label,
            ability: target.ability,
            cost: target.cost
        )
        let driftedPresentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(
                QuestionPresentation(
                    protocolVersion: 1,
                    questionVersion: 42,
                    questionKind: .playerWindowChooseOne,
                    choiceCount: driftedChoices.count,
                    choices: driftedChoices
                )
            )
        )
        assertActionWindowBindingFails(
            presentation: driftedPresentation,
            rawQuestion: rawQuestion
        )
    }

    private func assertMovementDowngradeFails(
        presentation: QuestionPresentation,
        rawQuestion: JSONValue
    ) throws {
        var downgradedChoices = presentation.choices
        for sourceIndex in [9, 11] {
            downgradedChoices[sourceIndex] = .gatheringEndTurn(
                sourceIndex: sourceIndex
            )
        }
        let downgradedPresentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(
                QuestionPresentation(
                    protocolVersion: 1,
                    questionVersion: 42,
                    questionKind: .playerWindowChooseOne,
                    choiceCount: downgradedChoices.count,
                    choices: downgradedChoices
                )
            )
        )
        assertActionWindowBindingFails(
            presentation: downgradedPresentation,
            rawQuestion: rawQuestion
        )
    }

    private func atticQ42Presentation(
        roleOrder: [AtticQ42Role]
    ) throws -> QuestionPresentation {
        let movement = try presentationFixture(
            "question-presentation-gathering-movement"
        )
        let choices = Array(movement.choices.prefix(9))
            + roleOrder.enumerated().map { offset, role in
                atticQ42PresentationChoice(
                    role: role,
                    sourceIndex: offset + 9
                )
            }
        return try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(
                QuestionPresentation(
                    protocolVersion: 1,
                    questionVersion: 42,
                    questionKind: .playerWindowChooseOne,
                    choiceCount: choices.count,
                    choices: choices
                )
            )
        )
    }

    private func atticQ42PresentationChoice(
        role: AtticQ42Role,
        sourceIndex: Int
    ) -> QuestionPresentation.Choice {
        switch role {
        case .atticMovement:
            .gatheringLocationMovement(
                sourceIndex: sourceIndex,
                cardCode: "c01113",
                locationID: q42AtticFixtureID,
                cost: .action(1)
            )
        case .hallwayInvestigation:
            .gatheringInvestigation(
                sourceIndex: sourceIndex,
                cardCode: "c01112",
                locationID: q42HallwayFixtureID
            )
        case .cellarMovement:
            .gatheringMovement(
                sourceIndex: sourceIndex,
                cardCode: "c01114",
                locationID: q42CellarFixtureID
            )
        }
    }

    private func atticQ42RawQuestion(
        roleOrder: [AtticQ42Role]
    ) throws -> JSONValue {
        guard case var .object(root) =
            try rawFixture("question-gathering-movement"),
            case let .array(movementChoices)? = root["choices"],
            movementChoices.indices.contains(11)
        else {
            throw GatheringActionWindowFixtureError.unexpectedShape
        }
        root["choices"] = try .array(
            Array(movementChoices.prefix(9))
                + (roleOrder.map {
                    try atticQ42RawChoice(
                        role: $0,
                        movementChoices: movementChoices
                    )
                })
        )
        return .object(root)
    }

    private func atticQ42RawChoice(
        role: AtticQ42Role,
        movementChoices: [JSONValue]
    ) throws -> JSONValue {
        switch role {
        case .atticMovement:
            try replacing(
                movementChoices[10],
                at: "/ability/type/cost",
                with: .object([
                    "contents": .number(.integer(1)),
                    "tag": .string("ActionCost"),
                ])
            )
        case .hallwayInvestigation:
            movementChoices[11]
        case .cellarMovement:
            movementChoices[9]
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

private func assertActionWindowBindingFails(
    presentation: QuestionPresentation,
    rawQuestion: JSONValue
) {
    #expect(throws: QuestionPresentationBindingError.self) {
        try presentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: 42
        )
    }
}

private enum GatheringActionWindowFixtureError: Error {
    case unexpectedShape
}
