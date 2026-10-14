@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Specialized ability wire-shape compatibility")
struct SpecializedAbilityWireShapeCompatibilityTests {
    @Test("Roland defeat reaction accepts legacy and schema 0.1.53 shapes")
    func rolandDefeatReactionAcceptsBothExactShapes() throws {
        let legacyQuestion = try #require(
            payload(named: "question-roland-defeat-reaction-pre-0.1.53", legacy: true)
                .supportedQuestion
        )
        guard case let .rolandDefeatReaction(legacyReaction) =
            legacyQuestion.choices.first?.content
        else {
            Issue.record("Expected legacy Roland reaction")
            return
        }
        #expect(legacyReaction.ability.cardCode.rawValue == "c01001")
        #expect(legacyReaction.defeatedEnemyID == RolandReactionFixtures.enemyID)

        let schemaQuestion = try #require(
            payload(named: "question-roland-defeat-reaction").supportedQuestion
        )
        guard case let .rolandDefeatReaction(schemaReaction) =
            schemaQuestion.choices.first?.content
        else {
            Issue.record("Expected schema 0.1.53 Roland reaction")
            return
        }
        #expect(schemaReaction.ability.cardCode.rawValue == "c01001")
        #expect(schemaReaction.defeatedEnemyID == RolandReactionFixtures.enemyID)
    }

    @Test("Roland mixed legacy and schema 0.1.53 shapes fail closed")
    func rolandDefeatReactionRejectsMixedShapes() throws {
        let schemaMissingResultLabel = try applying(
            operation: "remove",
            pointer: "/choices/0/ability/resultLabel",
            to: value(named: "question-roland-defeat-reaction")
        )
        try expectNoRolandReaction(schemaMissingResultLabel)

        let legacyWithOnlyChaosTokenEffects = try applying(
            operation: "add",
            replacement: .array([]),
            pointer: "/choices/0/ability/chaosTokenEffects",
            to: value(named: "question-roland-defeat-reaction-pre-0.1.53", legacy: true)
        )
        try expectNoRolandReaction(legacyWithOnlyChaosTokenEffects)
    }

    @Test("Round-end forced ability accepts legacy and schema 0.1.53 shapes")
    func roundEndForcedAbilityAcceptsBothExactShapes() throws {
        let legacyQuestion = try #require(
            payload(named: "question-round-end-forced-ability-pre-0.1.53", legacy: true)
                .supportedQuestion
        )
        guard case let .resolveForcedAbility(legacyChoice) = legacyQuestion.choices.first?.content
        else {
            Issue.record("Expected legacy Dissonant Voices forced ability")
            return
        }
        #expect(legacyChoice.ability.cardCode.rawValue == "c01165")
        #expect(legacyChoice.treacheryID == RoundTransitionFixtures.treacheryID)

        let schemaQuestion = try #require(
            payload(named: "question-round-end-forced-ability").supportedQuestion
        )
        guard case let .resolveForcedAbility(schemaChoice) = schemaQuestion.choices.first?.content
        else {
            Issue.record("Expected schema 0.1.53 Dissonant Voices forced ability")
            return
        }
        #expect(schemaChoice.ability.cardCode.rawValue == "c01165")
        #expect(schemaChoice.treacheryID == RoundTransitionFixtures.treacheryID)
    }

    @Test("Round-end mixed legacy and schema 0.1.53 shapes fail closed")
    func roundEndForcedAbilityRejectsMixedShapes() throws {
        var schemaMissingResultLabel = try value(named: "question-round-end-forced-ability")
        for pointer in [
            "/choices/0/ability/resultLabel",
            "/choices/0/messages/0/contents/contents/2/0/0/resultLabel",
        ] {
            schemaMissingResultLabel = try applying(
                operation: "remove",
                pointer: pointer,
                to: schemaMissingResultLabel
            )
        }
        try expectNoRoundEndForcedAbility(schemaMissingResultLabel)

        var legacyWithOnlyChaosTokenEffects = try value(
            named: "question-round-end-forced-ability-pre-0.1.53", legacy: true
        )
        for pointer in [
            "/choices/0/ability/chaosTokenEffects",
            "/choices/0/messages/0/contents/contents/2/0/0/chaosTokenEffects",
        ] {
            legacyWithOnlyChaosTokenEffects = try applying(
                operation: "add",
                replacement: .array([]),
                pointer: pointer,
                to: legacyWithOnlyChaosTokenEffects
            )
        }
        try expectNoRoundEndForcedAbility(legacyWithOnlyChaosTokenEffects)
    }

    private func fixtureData(named fileName: String, legacy: Bool = false) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: fileName,
            withExtension: "json",
            subdirectory: legacy ? "Fixtures/LegacyContract" : "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    private func value(named fileName: String, legacy: Bool = false) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: fileName, legacy: legacy))
    }

    private func payload(named fileName: String, legacy: Bool = false) throws
        -> BasicChoiceQuestionPayload
    {
        try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixtureData(named: fileName, legacy: legacy)
        )
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

    private func expectNoRolandReaction(_ value: JSONValue) throws {
        let question = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(value)
        ).supportedQuestion
        #expect(question?.choices.contains(where: { choice in
            if case .rolandDefeatReaction = choice.content {
                true
            } else {
                false
            }
        }) != true)
    }

    private func expectNoRoundEndForcedAbility(_ value: JSONValue) throws {
        let question = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(value)
        ).supportedQuestion
        #expect(question?.choices.contains(where: { choice in
            if case .resolveForcedAbility = choice.content {
                true
            } else {
                false
            }
        }) != true)
    }
}
