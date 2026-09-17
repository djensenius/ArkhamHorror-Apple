@testable import ArkhamHorrorShared
import Foundation
import Testing

private let q42HallwayFixtureID =
    "fda9afef-4166-4c9f-962e-eed6e8cbee25"
private let q42CellarFixtureID =
    "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
private let q42AtticFixtureID =
    "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"

enum AtticQ42Role {
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
            [
                .cellarMovement,
                .atticMovement,
                .hallwayInvestigation,
            ],
        ]
        for handCardCount in [6, 7] {
            for roleOrder in roleOrders {
                try assertAtticQ42BindingSucceeds(
                    handCardCount: handCardCount,
                    roleOrder: roleOrder
                )
            }
        }

        for (handCardCount, roleOrder) in [
            (6, roleOrders[0]),
            (7, roleOrders[2]),
        ] {
            try assertAtticQ42DriftFails(
                handCardCount: handCardCount,
                roleOrder: roleOrder
            )
        }
    }

    @Test("Attic Q42 rejects unsupported hand-card counts")
    func gatheringAtticQ42RejectsUnsupportedChoiceCount() throws {
        let presentation = try atticQ42Presentation(
            roleOrder: [
                .cellarMovement,
                .atticMovement,
                .hallwayInvestigation,
            ],
            handCardCount: 7
        )
        let unsupported = try presentationData(
            withExtraCardInsertedInto: presentation
        )
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: unsupported
            )
        }
    }
}

private extension GatheringActionWindowBindingTests {
    func assertAtticQ42BindingSucceeds(
        handCardCount: Int,
        roleOrder: [AtticQ42Role]
    ) throws {
        let rawQuestion = try atticQ42RawQuestion(
            roleOrder: roleOrder,
            handCardCount: handCardCount
        )
        let presentation = try atticQ42Presentation(
            roleOrder: roleOrder,
            handCardCount: handCardCount
        )
        let binding = try presentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: 42
        )
        #expect(
            binding.presentation.choices.count ==
                handCardCount + 6
        )
    }

    func assertAtticQ42DriftFails(
        handCardCount: Int,
        roleOrder: [AtticQ42Role]
    ) throws {
        let rawQuestion = try atticQ42RawQuestion(
            roleOrder: roleOrder,
            handCardCount: handCardCount
        )
        let presentation = try atticQ42Presentation(
            roleOrder: roleOrder,
            handCardCount: handCardCount
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

    func presentationData(
        withExtraCardInsertedInto presentation: QuestionPresentation
    ) throws -> Data {
        guard case var .object(encoded) = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(presentation)
        ),
            case var .array(choices)? = encoded["choices"],
            case let .object(extraCard) = choices[2]
        else {
            throw GatheringActionWindowFixtureError.unexpectedShape
        }
        choices.insert(.object(extraCard), at: 2)
        for sourceIndex in choices.indices {
            guard case var .object(choice) = choices[sourceIndex] else {
                throw GatheringActionWindowFixtureError.unexpectedShape
            }
            choice["sourceIndex"] = .number(.integer(Int64(sourceIndex)))
            choices[sourceIndex] = .object(choice)
        }
        encoded["choiceCount"] = .number(.integer(Int64(choices.count)))
        encoded["choices"] = .array(choices)
        return try ContractJSON.encode(JSONValue.object(encoded))
    }

    func assertRawTargetDriftFails(
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

    func assertPresentationTargetDriftFails(
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

    func assertMovementDowngradeFails(
        presentation: QuestionPresentation,
        rawQuestion: JSONValue
    ) throws {
        var downgradedChoices = presentation.choices
        let movementSourceIndices = downgradedChoices.suffix(3)
            .filter { $0.kind == .move }
            .map(\.sourceIndex)
        for sourceIndex in movementSourceIndices {
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

    func atticQ42Presentation(
        roleOrder: [AtticQ42Role],
        handCardCount: Int = 6
    ) throws -> QuestionPresentation {
        guard [6, 7].contains(handCardCount) else {
            throw GatheringActionWindowFixtureError.unexpectedShape
        }
        let movement = try presentationFixture(
            "question-presentation-gathering-movement"
        )
        var choices = Array(movement.choices.prefix(9))
        if handCardCount == 7 {
            choices.insert(
                .gatheringCardTarget(
                    sourceIndex: 2,
                    cardID:
                    "fb0d11c0-e7fd-42e9-bfc3-851bfa025837"
                ),
                at: 2
            )
            for sourceIndex in 3 ..< choices.count {
                choices[sourceIndex] = choices[sourceIndex]
                    .replacingSourceIndex(sourceIndex)
            }
        }
        let firstRoleSourceIndex = choices.count
        choices += roleOrder.enumerated().map { offset, role in
            atticQ42PresentationChoice(
                role: role,
                sourceIndex: offset + firstRoleSourceIndex
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

    func atticQ42PresentationChoice(
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
}
