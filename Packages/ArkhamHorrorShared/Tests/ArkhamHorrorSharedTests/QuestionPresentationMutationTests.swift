@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Semantic question presentation governed mutations")
struct QuestionPresentationMutationTests {
    private static let governedPresentationFixtures: Set<String> = [
        "contracts/fixtures/question-presentation-gathering-act-objective.json",
        "contracts/fixtures/question-presentation-gathering-act-advance.json",
    ]

    @Test("All seven backend-published Gathering mutations fail during decoding")
    func governedGatheringMutationsFailClosed() throws {
        let entries = try governedNegativeEntries()
        #expect(entries.count == 7)
        for entry in entries {
            try expectDecodingRejection(for: entry)
        }
    }

    private func governedNegativeEntries() throws -> [[String: JSONValue]] {
        let manifest = try ContractJSON.decode(
            JSONValue.self,
            from: fixtureData(named: "manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negativeFixtures)? = root["negativeFixtures"]
        else { throw TestFailure() }
        return negativeFixtures.compactMap { value in
            guard case let .object(entry) = value,
                  case let .string(baseFixture)? = entry["basePositiveFixture"],
                  Self.governedPresentationFixtures.contains(baseFixture)
            else { return nil }
            return entry
        }
    }

    private func expectDecodingRejection(
        for entry: [String: JSONValue]
    ) throws {
        guard case let .string(baseFixture)? = entry["basePositiveFixture"],
              case let .string(basePointer)? = entry["basePointer"],
              case let .object(mutation)? = entry["mutation"],
              case let .string(operation)? = mutation["op"],
              case let .string(pointer)? = mutation["pointer"],
              let filename = baseFixture.split(separator: "/").last
        else { throw TestFailure() }

        let fixtureName = String(filename.dropLast(".json".count))
        let mutated = try EnemyAttackFixtures.applying(
            operation: operation,
            path: (basePointer + pointer).split(separator: "/"),
            replacement: mutation["value"],
            to: fixtureValue(named: fixtureName)
        )
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: ContractJSON.encode(mutated)
            )
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
}

@MainActor
@Suite("Gathering advance-act semantic mutations")
struct GatheringAdvanceActSemanticMutationTests {
    private struct Mutation {
        let fixture: String
        let operation: String
        let pointer: String
        let replacement: JSONValue
    }

    private static let mutations: [Mutation] = [
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/questionVersion",
            replacement: .number(.integer(33))
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/questionKind",
            replacement: .string("chooseOne")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/actorId",
            replacement: .string("c01002")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/kind",
            replacement: .string("useAbility")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/entity/id",
            replacement: .string("c01109")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/ability/cardCode",
            replacement: .string("c01109")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/ability/index",
            replacement: .number(.integer(998))
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/ability/type",
            replacement: .string("action")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/ability/actions",
            replacement: .array([.string("activate")])
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/ability/canBeCancelled",
            replacement: .bool(false)
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/cost/amount/kind",
            replacement: .string("fixed")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/cost/amount/value",
            replacement: .number(.integer(3))
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "replace",
            pointer: "/choices/12/cost/scope/kind",
            replacement: .string("sameLocation")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-objective",
            operation: "add",
            pointer: "/choices/12/label",
            replacement: .object([
                "kind": .string("embeddedI18n"),
                "text": .string("$continue"),
            ])
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-advance",
            operation: "replace",
            pointer: "/questionVersion",
            replacement: .number(.integer(36))
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-advance",
            operation: "replace",
            pointer: "/questionKind",
            replacement: .string("playerWindowChooseOne")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-advance",
            operation: "replace",
            pointer: "/choices/0/entity/id",
            replacement: .string("c01109")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-advance",
            operation: "replace",
            pointer: "/choices/0/kind",
            replacement: .string("chooseTarget")
        ),
        Mutation(
            fixture: "question-presentation-gathering-act-advance",
            operation: "add",
            pointer: "/choices/0/label",
            replacement: .object([
                "kind": .string("embeddedI18n"),
                "text": .string("$continue"),
            ])
        ),
    ]

    @Test("Every unsupported Gathering advance-act field fails during decoding")
    func unsupportedFieldsFailClosed() throws {
        for mutation in Self.mutations {
            let mutated = try EnemyAttackFixtures.applying(
                operation: mutation.operation,
                path: mutation.pointer.split(separator: "/"),
                replacement: mutation.replacement,
                to: fixtureValue(named: mutation.fixture)
            )
            #expect(throws: DecodingError.self) {
                try ContractJSON.decode(
                    QuestionPresentation.self,
                    from: ContractJSON.encode(mutated)
                )
            }
        }
    }

    private func fixtureValue(named name: String) throws -> JSONValue {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(
            JSONValue.self,
            from: Data(contentsOf: url)
        )
    }
}

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
}
