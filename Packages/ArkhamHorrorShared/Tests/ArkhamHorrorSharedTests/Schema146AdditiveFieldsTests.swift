@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Schema 0.1.46 additive fields")
struct Schema146AdditiveFieldsTests {
    @Test("presentation abilities preserve default additive fields and still accept old shape")
    func presentationAbilityDefaultFields() throws {
        let oldShape = try Self.decodeAbility(Self.presentationAbilityJSON)
        #expect(oldShape.blocksIn == nil)
        #expect(oldShape.nonBlocking == nil)

        let withDefaults = try Self.decodeAbility(
            Self.presentationAbilityJSON.dropLast() + #", "blocksIn": null, "nonBlocking": false}"#
        )
        #expect(withDefaults.blocksIn == JSONValue.null)
        #expect(withDefaults.nonBlocking == false)

        let encoded = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(withDefaults)
        )
        guard case let .object(object) = encoded else {
            Issue.record("Expected ability object")
            return
        }
        #expect(object["blocksIn"] == JSONValue.null)
        #expect(object["nonBlocking"] == JSONValue.bool(false))
    }

    @Test("presentation abilities reject non-default additive fields")
    func presentationAbilityRejectsNonDefaults() {
        #expect(throws: DecodingError.self) {
            try Self.decodeAbility(
                Self.presentationAbilityJSON.dropLast() + #", "nonBlocking": true}"#
            )
        }
        #expect(throws: DecodingError.self) {
            try Self.decodeAbility(
                Self.presentationAbilityJSON.dropLast() + #", "blocksIn": {"tag":"Future"}}"#
            )
        }
    }

    @Test("round-end forced ability message binds the prompted investigator")
    func roundEndForcedAbilityAcceptsNonRolandInvestigator() throws {
        var value = try fixtureValue("question-round-end-forced-ability")
        for pointer in [
            "/choices/0/investigatorId",
            "/choices/0/messages/0/contents/contents/0",
        ] {
            value = try applyingReplace(pointer, with: .string("c01002"), to: value)
        }
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(value)
        )
        guard case let .resolveForcedAbility(choice)? =
            payload.supportedQuestion?.choices.first?.content
        else {
            Issue.record("Expected non-Roland round-end forced ability to parse")
            return
        }
        #expect(choice.ability.investigatorID.rawValue.rawValue == "c01002")
    }

    @Test("raw prompts accept missing additive keys and reject non-default additive values")
    func rawPromptAdditiveDefaults() throws {
        try assertRoundEndForcedAbility(mutating: "question-round-end-forced-ability", removals: [
            "/choices/0/ability/blocksIn",
            "/choices/0/ability/nonBlocking",
            "/choices/0/windows/0/windowConditionTick",
            "/choices/0/messages/0/contents/contents/1/0/windowConditionTick",
            "/choices/0/messages/0/contents/contents/2/0/1/0/windowConditionTick",
            "/choices/0/messages/0/contents/contents/2/0/0/blocksIn",
            "/choices/0/messages/0/contents/contents/2/0/0/nonBlocking",
        ])
        try assertUpdateRequired(
            fixture: "question-round-end-forced-ability",
            pointer: "/choices/0/ability/nonBlocking",
            replacement: .bool(true)
        )
        try assertUpdateRequired(
            fixture: "question-round-end-forced-ability",
            pointer: "/choices/0/ability/blocksIn",
            replacement: .object(["tag": .string("Future")])
        )
        try assertUpdateRequired(
            fixture: "question-round-end-forced-ability",
            pointer: "/choices/0/windows/0/windowConditionTick",
            replacement: .number(.integer(1))
        )

        try assertEnemyAttack(mutating: "question-enemy-attack", removals: [
            "/choices/0/messages/0/contents/contents/attackDamageReplacement",
        ])
        try assertUpdateRequired(
            fixture: "question-enemy-attack",
            pointer: "/choices/0/messages/0/contents/contents/attackDamageReplacement",
            replacement: .array([.null])
        )
    }

    @Test("public game optional 0.1.46 fields decode present and missing")
    func publicGameAdditiveFields() throws {
        let getGame = try ContractJSON.decode(GetGameEnvelope.self, from: fixtureData("get-game"))
        #expect(getGame.game.retiredInvestigators != nil)
        if case let .scenarioOnly(scenario) = getGame.game.mode {
            #expect(scenario.customChaosBags != nil)
        } else {
            Issue.record("Expected scenario-only fixture")
        }

        var value = try fixtureValue("get-game")
        value = try applyingRemove("/game/retiredInvestigators", to: value)
        value = try applyingRemove("/game/mode/That/customChaosBags", to: value)
        let oldShape = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(value)
        )
        #expect(oldShape.game.retiredInvestigators == nil)
        if case let .scenarioOnly(scenario) = oldShape.game.mode {
            #expect(scenario.customChaosBags == nil)
        } else {
            Issue.record("Expected scenario-only fixture")
        }
    }

    private static let presentationAbilityJSON =
        #"{"cardCode":"c01007","index":2,"type":"forced","actions":[],"canBeCancelled":true}"#

    private static func decodeAbility(_ json: String) throws -> QuestionPresentation.Ability {
        try ContractJSON.decode(QuestionPresentation.Ability.self, from: Data(json.utf8))
    }

    private func assertRoundEndForcedAbility(mutating fixture: String, removals: [String]) throws {
        let payload = try payloadAfterRemoving(removals, from: fixture)
        guard case let .resolveForcedAbility(choice)? =
            payload.supportedQuestion?.choices.first?.content
        else {
            Issue.record("Expected round-end forced ability to parse")
            return
        }
        #expect(choice.ability.cardCode.rawValue == "c01165")
    }

    private func assertEnemyAttack(mutating fixture: String, removals: [String]) throws {
        let payload = try payloadAfterRemoving(removals, from: fixture)
        guard case let .resolveEnemyAttack(enemyID, investigatorID, messages)? =
            payload.supportedQuestion?.choices.first?.content
        else {
            Issue.record("Expected enemy attack to parse")
            return
        }
        #expect(enemyID == EnemyAttackFixtures.enemyID)
        #expect(investigatorID == EnemyAttackFixtures.investigatorID)
        #expect(messages.count == 1)
    }

    private func payloadAfterRemoving(
        _ removals: [String],
        from fixture: String
    ) throws -> BasicChoiceQuestionPayload {
        var value = try fixtureValue(fixture)
        for pointer in removals {
            value = try applyingRemove(pointer, to: value)
        }
        return try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(value)
        )
    }

    private func assertUpdateRequired(
        fixture: String,
        pointer: String,
        replacement: JSONValue
    ) throws {
        let mutated = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: pointer.split(separator: "/"),
            replacement: replacement,
            to: fixtureValue(fixture)
        )
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(mutated)
        )
        if let question = payload.supportedQuestion {
            #expect(question.choices.allSatisfy { choice in
                if case .unsupported = choice.content {
                    return true
                }
                return false
            })
        }
    }

    private func applyingReplace(
        _ pointer: String,
        with replacement: JSONValue,
        to value: JSONValue
    ) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: "replace",
            path: pointer.split(separator: "/"),
            replacement: replacement,
            to: value
        )
    }

    private func applyingRemove(_ pointer: String, to value: JSONValue) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: "remove",
            path: pointer.split(separator: "/"),
            replacement: nil,
            to: value
        )
    }

    private func fixtureValue(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }
}

func jsonObjectTag(_ value: JSONValue?) -> String? {
    guard case let .object(object)? = value,
          case let .string(tag)? = object["tag"]
    else { return nil }
    return tag
}
