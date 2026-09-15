@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Gathering raw choice binding mutations")
struct GatheringRawChoiceBindingMutationTests {
    private struct Mutation {
        let rawFixture: String
        let presentationFixture: String
        let questionVersion: Int
        let pointer: String
        let replacement: JSONValue
    }

    private static let mutations: [Mutation] = [
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/0/component/investigatorId",
            replacement: .string("c01002")
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/2/target/contents",
            replacement: .string("00000000-0000-4000-8000-000000000099")
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/8/messages/0/contents",
            replacement: .string("c01002")
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/12/investigatorId",
            replacement: .string("c01002")
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/12/ability/source/contents",
            replacement: .string("c01109")
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/12/ability/index",
            replacement: .number(.integer(998))
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/12/ability/type/abilityType/cost/contents/0/contents",
            replacement: .number(.integer(3))
        ),
        Mutation(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            pointer: "/choices/12/ability/canBeCancelled",
            replacement: .bool(false)
        ),
        Mutation(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35,
            pointer: "/choices/0/target/contents",
            replacement: .string("c01109")
        ),
        Mutation(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35,
            pointer: "/choices/0/messages/0/contents/0",
            replacement: .string("c01109")
        ),
        Mutation(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35,
            pointer: "/choices/0/messages/0/contents/2",
            replacement: .string("AdvancedWithoutClues")
        ),
    ]

    @Test("Every governed Q34 semantic choice is bound to the complete raw array")
    func governedSemanticChoiceMutationsFailClosed() throws {
        let mutations: [(pointer: String, replacement: JSONValue)] = [
            ("/choices/0/actorId", .string("c01002")),
            (
                "/choices/2/entity/id",
                .string("00000000-0000-4000-8000-000000000099")
            ),
            ("/choices/10/ability/index", .number(.integer(99))),
        ]
        let raw = try fixtureValue(named: "question-gathering-act-objective")
        for mutation in mutations {
            let presentationValue = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: mutation.pointer.split(separator: "/"),
                replacement: mutation.replacement,
                to: fixtureValue(named: "question-presentation-gathering-act-objective")
            )
            let presentation = try ContractJSON.decode(
                QuestionPresentation.self,
                from: ContractJSON.encode(presentationValue)
            )
            #expect(throws: QuestionPresentationBindingError.self) {
                try presentation.bind(to: raw, expectedQuestionVersion: 34)
            }
        }
    }

    @Test("Coordinated regenerated Q34 identities retain exact full-array binding")
    func coordinatedRegeneratedIDsBind() throws {
        let replacements = [
            "f971e011-b98d-4583-81b0-d2a378866698":
                "00000000-0000-4000-8000-000000000001",
            "42f70875-1782-4fa6-a034-c16a3406e8f9":
                "00000000-0000-4000-8000-000000000002",
            "001b6b9f-fc30-413d-855c-039ffcba4d15":
                "00000000-0000-4000-8000-000000000003",
            "1b215bc4-4405-41ac-ba8d-75bd2e4dab9a":
                "00000000-0000-4000-8000-000000000004",
            "d2458ecc-5f9f-4ba7-8b58-1474e70e8806":
                "00000000-0000-4000-8000-000000000005",
            "377b1268-96b7-4806-b999-5574020a28f6":
                "00000000-0000-4000-8000-000000000006",
            "d5a66e84-c729-4066-8475-d8a155609025":
                "00000000-0000-4000-8000-000000000007",
            "2d2310e9-f351-4688-aa55-e33666bb356c":
                "00000000-0000-4000-8000-000000000008",
        ]
        let raw = try replacingStrings(
            in: fixtureValue(named: "question-gathering-act-objective"),
            with: replacements
        )
        let presentationValue = try replacingStrings(
            in: fixtureValue(named: "question-presentation-gathering-act-objective"),
            with: replacements
        )
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(presentationValue)
        )

        let bound = try presentation.bind(to: raw, expectedQuestionVersion: 34)

        #expect(bound.rawChoices.count == 13)
        #expect(
            bound.descriptor(forSourceIndex: 10)?.entity?.id ==
                "00000000-0000-4000-8000-000000000008"
        )
    }

    @Test("Every governed raw choice mutation fails during binding")
    func governedRawChoiceMutationsFailClosed() throws {
        for mutation in Self.mutations {
            let raw = try fixtureValue(named: mutation.rawFixture)
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: mutation.pointer.split(separator: "/"),
                replacement: mutation.replacement,
                to: raw
            )
            let presentation = try ContractJSON.decode(
                QuestionPresentation.self,
                from: fixtureData(named: mutation.presentationFixture)
            )
            #expect(throws: QuestionPresentationBindingError.self) {
                try presentation.bind(
                    to: mutated,
                    expectedQuestionVersion: mutation.questionVersion
                )
            }
        }
    }

    private func fixtureValue(named name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: name))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    private func replacingStrings(
        in value: JSONValue,
        with replacements: [String: String]
    ) -> JSONValue {
        switch value {
        case let .string(string):
            .string(replacements[string] ?? string)
        case let .array(elements):
            .array(elements.map { replacingStrings(in: $0, with: replacements) })
        case let .object(object):
            .object(object.mapValues { replacingStrings(in: $0, with: replacements) })
        case .null, .bool, .number:
            value
        }
    }
}
