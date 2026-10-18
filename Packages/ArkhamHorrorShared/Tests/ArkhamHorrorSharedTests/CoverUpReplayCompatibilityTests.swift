@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Cover Up reaction replay compatibility")
struct CoverUpReplayCompatibilityTests {
    @Test("Historical production 0.1.40 Cover Up replay prompt still parses strictly")
    func legacyProductionReplayPromptParsesStrictly() throws {
        let raw = try legacyReplayQ33Value()
        let payload = try CoverUpReactionFixtures.payload(raw)
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .windowChooseOne)
        #expect(question.choices.map(\.index) == [0, 1])
        #expect(try ProductionAssignmentReplayCanonicalJSON.promptDigest(raw)
            == "7c70ba6b40ad8c9965a8a9c8f6644dec60942f73a6db63e3dcb58872832fcd98")

        guard case let .coverUpReaction(reaction) = question.choices[0].content else {
            Issue.record("Expected historical Cover Up reaction")
            return
        }
        #expect(reaction.ability.cardCode.rawValue == "c01007")
        #expect(reaction.locationID.codingKey.stringValue
            == "4c9a45da-8069-4d10-94d1-451a5e0ae565")
        #expect(reaction.skillTestID.codingKey.stringValue
            == "1bd2b319-9123-4930-b9bb-253791bef36a")
    }

    @Test("Schema 0.1.53 Cover Up fixture still parses strictly")
    func schema153FixtureParsesStrictly() throws {
        let raw = try CoverUpReactionFixtures.value()
        let payload = try CoverUpReactionFixtures.payload(raw)
        let question = try #require(payload.supportedQuestion)
        guard case let .coverUpReaction(reaction) = question.choices[0].content else {
            Issue.record("Expected schema 0.1.53 Cover Up reaction")
            return
        }
        #expect(reaction.locationID == CoverUpReactionFixtures.locationID)
        #expect(reaction.skillTestID == CoverUpReactionFixtures.skillTestID)
    }

    @Test("Mixed legacy and schema 0.1.53 Cover Up shapes fail closed")
    func mixedWireShapesFailClosed() throws {
        let schema153 = try CoverUpReactionFixtures.value()
        let withoutChaosTokenEffects = try applying(
            operation: "remove",
            pointer: "/choices/0/ability/chaosTokenEffects",
            to: schema153
        )
        let fiveElementMatcherWithoutNewFields = try applying(
            operation: "remove",
            pointer: "/choices/0/ability/resultLabel",
            to: withoutChaosTokenEffects
        )
        try expectNoCoverUpReaction(fiveElementMatcherWithoutNewFields)

        let fourElementMatcherWithNewFieldsStep = try applying(
            operation: "remove",
            pointer: "/choices/0/ability/window/contents/4",
            to: schema153
        )
        let fourElementMatcherWithNewFields = try applying(
            operation: "remove",
            pointer: "/choices/0/ability/type/window/contents/4",
            to: fourElementMatcherWithNewFieldsStep
        )
        try expectNoCoverUpReaction(fourElementMatcherWithNewFields)
    }

    private func legacyReplayQ33Value() throws -> JSONValue {
        let evidence = try ContractJSON.decode(
            ProductionCoverUpReplayEvidence.self,
            from: replayData("cover-up-production-replay")
        )
        let state = try ContractJSON.decode(
            JSONValue.self,
            from: Data(evidence.use.stateBeforeUTF8.utf8)
        )
        guard case let .object(root) = state,
              case let .object(contents)? = root["contents"],
              case let .object(questions)? = contents["question"],
              let q33 = questions[evidence.use.playerID.codingKey.stringValue]
        else { throw TestFailure() }
        return q33
    }

    private func replayData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Replay"
        ))
        return try Data(contentsOf: url)
    }

    private func applying(
        operation: String,
        replacement: JSONValue? = nil,
        pointer: String,
        to value: JSONValue
    ) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: operation,
            path: pointer.split(separator: "/"),
            replacement: replacement,
            to: value
        )
    }

    private func expectNoCoverUpReaction(_ value: JSONValue) throws {
        let question = try CoverUpReactionFixtures.payload(value).supportedQuestion
        #expect(question?.choices.contains(where: { choice in
            if case .coverUpReaction = choice.content {
                true
            } else {
                false
            }
        }) != true)
    }
}
