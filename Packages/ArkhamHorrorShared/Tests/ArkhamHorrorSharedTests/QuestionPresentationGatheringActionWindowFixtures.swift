@testable import ArkhamHorrorShared
import Foundation
import Testing

extension GatheringActionWindowBindingTests {
    func atticQ42RawQuestion(
        roleOrder: [AtticQ42Role],
        handCardCount: Int = 6
    ) throws -> JSONValue {
        guard case var .object(root) =
            try rawFixture("question-gathering-movement"),
            case let .array(movementChoices)? = root["choices"],
            movementChoices.indices.contains(11),
            [6, 7].contains(handCardCount)
        else {
            throw GatheringActionWindowFixtureError.unexpectedShape
        }
        var actionChoices = Array(movementChoices.prefix(2))
        if handCardCount == 7 {
            var drawnCard = try replacing(
                movementChoices[7],
                at: "/target/contents",
                with:
                .string("fb0d11c0-e7fd-42e9-bfc3-851bfa025837")
            )
            drawnCard = try replacing(
                drawnCard,
                at: "/messages/0/contents/1/contents/id",
                with:
                .string("fb0d11c0-e7fd-42e9-bfc3-851bfa025837")
            )
            actionChoices.append(drawnCard)
        }
        actionChoices += movementChoices[2 ... 8]
        root["choices"] = try .array(
            actionChoices
                + (roleOrder.map {
                    try atticQ42RawChoice(
                        role: $0,
                        movementChoices: movementChoices
                    )
                })
        )
        return .object(root)
    }

    func atticQ42RawChoice(
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

    func presentationFixture(
        _ name: String
    ) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    func rawFixture(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixture(name))
    }

    func replacing(
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

    func fixture(_ name: String) throws -> Data {
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

func assertActionWindowBindingFails(
    presentation: QuestionPresentation,
    rawQuestion: JSONValue,
    expectedQuestionVersion: Int = 42
) {
    #expect(throws: QuestionPresentationBindingError.self) {
        try presentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: expectedQuestionVersion
        )
    }
}

enum GatheringActionWindowFixtureError: Error {
    case unexpectedShape
}
