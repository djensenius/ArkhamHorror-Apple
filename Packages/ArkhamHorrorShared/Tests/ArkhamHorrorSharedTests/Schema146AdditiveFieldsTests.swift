@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Schema 0.1.46 additive fields")
struct Schema146AdditiveFieldsTests {
    @Test("v2 presentation abilities reject removed additive fields")
    func presentationAbilityRemovedFieldsReject() throws {
        _ = try decodeSchema146Ability(schema146PresentationAbilityJSON)
        // `blocksIn`/`nonBlocking` were raw Ability compatibility fields in schema 0.1.46.
        // Question/Presentation.hs no longer publishes them in protocolVersion 2, so the
        // closed presentation decoder rejects even their former default values.
        #expect(throws: DecodingError.self) {
            try decodeSchema146Ability(
                schema146PresentationAbilityJSON.dropLast()
                    + #", "blocksIn": null, "nonBlocking": false}"#
            )
        }
    }

    @Test("explicit presentation ability defaults no longer decode as Gathering references")
    func presentationAbilityDefaultsRejectBeforeOverlayMatching() throws {
        var value = try schema146FixtureValue("question-presentation-gathering-movement")
        for sourceIndex in [9, 10, 11] {
            value = try schema146ApplyingReplace(
                "/choices/\(sourceIndex)/ability/blocksIn", with: .null, to: value
            )
            value = try schema146ApplyingReplace(
                "/choices/\(sourceIndex)/ability/nonBlocking", with: .bool(false), to: value
            )
        }
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: ContractJSON.encode(value)
            )
        }
    }

    @Test("presentation abilities reject non-default additive fields")
    func presentationAbilityRejectsNonDefaults() {
        #expect(throws: DecodingError.self) {
            try decodeSchema146Ability(
                schema146PresentationAbilityJSON.dropLast() + #", "nonBlocking": true}"#
            )
        }
        #expect(throws: DecodingError.self) {
            try decodeSchema146Ability(
                schema146PresentationAbilityJSON.dropLast()
                    + #", "blocksIn": {"tag":"Future"}}"#
            )
        }
    }

    @Test("round-end forced ability message binds the prompted investigator")
    func roundEndForcedAbilityAcceptsNonRolandInvestigator() throws {
        var value = try schema146FixtureValue("question-round-end-forced-ability")
        for pointer in [
            "/choices/0/investigatorId",
            "/choices/0/messages/0/contents/contents/0",
        ] {
            value = try schema146ApplyingReplace(pointer, with: .string("c01002"), to: value)
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
        try assertRoundEndForcedAbility(mutating: "question-round-end-forced-ability")
        try assertRoundEndRejectsNonDefaultAdditives()
        try assertReactionWindowConditionTickRejected()
        try assertEnemyAttack(mutating: "question-enemy-attack")
        try assertUpdateRequired(
            fixture: "question-enemy-attack",
            replacements: [
                (
                    "/choices/0/messages/0/contents/contents/attackDamageReplacement",
                    .array([.null])
                ),
            ]
        )
    }

    @Test("public game optional 0.1.46 fields decode present and missing")
    func publicGameAdditiveFields() throws {
        let getGame = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: schema146FixtureData("get-game")
        )
        #expect(getGame.game.retiredInvestigators != nil)
        if case let .scenarioOnly(scenario) = getGame.game.mode {
            #expect(scenario.customChaosBags != nil)
        } else {
            Issue.record("Expected scenario-only fixture")
        }

        var value = try schema146FixtureValue("get-game")
        value = try schema146ApplyingRemove("/game/retiredInvestigators", to: value)
        value = try schema146ApplyingRemove("/game/mode/That/customChaosBags", to: value)
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
}

private let schema146PresentationAbilityJSON =
    #"{"cardCode":"c01007","index":2,"type":"forced","actions":[],"canBeCancelled":true}"#

private func decodeSchema146Ability(_ json: String) throws -> QuestionPresentation.Ability {
    try ContractJSON.decode(QuestionPresentation.Ability.self, from: Data(json.utf8))
}

private func assertRoundEndForcedAbility(mutating fixture: String) throws {
    let removals = [
        "/choices/0/ability/blocksIn",
        "/choices/0/ability/nonBlocking",
        "/choices/0/windows/0/windowConditionTick",
        "/choices/0/messages/0/contents/contents/1/0/windowConditionTick",
        "/choices/0/messages/0/contents/contents/2/0/1/0/windowConditionTick",
        "/choices/0/messages/0/contents/contents/2/0/0/blocksIn",
        "/choices/0/messages/0/contents/contents/2/0/0/nonBlocking",
    ]
    let payload = try schema146PayloadAfterRemoving(removals, from: fixture)
    guard case let .resolveForcedAbility(choice)? =
        payload.supportedQuestion?.choices.first?.content
    else {
        Issue.record("Expected round-end forced ability to parse")
        return
    }
    #expect(choice.ability.cardCode.rawValue == "c01165")
}

private func assertRoundEndRejectsNonDefaultAdditives() throws {
    try assertUpdateRequired(
        fixture: "question-round-end-forced-ability",
        replacements: [
            ("/choices/0/ability/nonBlocking", .bool(true)),
            ("/choices/0/messages/0/contents/contents/2/0/0/nonBlocking", .bool(true)),
        ]
    )
    try assertUpdateRequired(
        fixture: "question-round-end-forced-ability",
        replacements: [
            ("/choices/0/ability/blocksIn", .object(["tag": .string("Future")])),
            (
                "/choices/0/messages/0/contents/contents/2/0/0/blocksIn",
                .object(["tag": .string("Future")])
            ),
        ]
    )
    try assertUpdateRequired(
        fixture: "question-round-end-forced-ability",
        replacements: [
            ("/choices/0/windows/0/windowConditionTick", .number(.integer(1))),
            (
                "/choices/0/messages/0/contents/contents/1/0/windowConditionTick",
                .number(.integer(1))
            ),
            (
                "/choices/0/messages/0/contents/contents/2/0/1/0/windowConditionTick",
                .number(.integer(1))
            ),
        ]
    )
}

private func assertReactionWindowConditionTickRejected() throws {
    for fixture in ["question-cover-up-reaction", "question-roland-defeat-reaction"] {
        try assertUpdateRequired(
            fixture: fixture,
            replacements: [("/choices/0/windows/0/windowConditionTick", .number(.integer(1)))]
        )
    }
}

private func assertEnemyAttack(mutating fixture: String) throws {
    let payload = try schema146PayloadAfterRemoving(
        ["/choices/0/messages/0/contents/contents/attackDamageReplacement"],
        from: fixture
    )
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

private func schema146PayloadAfterRemoving(
    _ removals: [String],
    from fixture: String
) throws -> BasicChoiceQuestionPayload {
    var value = try schema146FixtureValue(fixture)
    for pointer in removals {
        value = try schema146ApplyingRemove(pointer, to: value)
    }
    return try ContractJSON.decode(
        BasicChoiceQuestionPayload.self,
        from: ContractJSON.encode(value)
    )
}

private func assertUpdateRequired(
    fixture: String,
    replacements: [(pointer: String, replacement: JSONValue)]
) throws {
    var mutated = try schema146FixtureValue(fixture)
    for replacement in replacements {
        mutated = try schema146ApplyingReplace(
            replacement.pointer,
            with: replacement.replacement,
            to: mutated
        )
    }
    let payload = try ContractJSON.decode(
        BasicChoiceQuestionPayload.self,
        from: ContractJSON.encode(mutated)
    )
    if let question = payload.supportedQuestion {
        let unsupportedChoices = question.choices.filter { choice in
            if case .unsupported = choice.content {
                return true
            }
            return false
        }
        let grantsAuthority = question.choices.contains {
            grantsGovernedAuthority($0.content)
        }
        #expect(!unsupportedChoices.isEmpty)
        #expect(!grantsAuthority)
    }
}

private func grantsGovernedAuthority(_ content: BasicChoiceContent) -> Bool {
    switch content {
    case .resolveForcedAbility, .coverUpReaction, .rolandDefeatReaction,
         .resolveEnemyAttack:
        true
    default:
        false
    }
}

private func schema146ApplyingReplace(
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

private func schema146ApplyingRemove(_ pointer: String, to value: JSONValue) throws -> JSONValue {
    try EnemyAttackFixtures.applying(
        operation: "remove",
        path: pointer.split(separator: "/"),
        replacement: nil,
        to: value
    )
}

private func schema146FixtureValue(_ name: String) throws -> JSONValue {
    try ContractJSON.decode(JSONValue.self, from: schema146FixtureData(name))
}

private func schema146FixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures/Contract"
    ))
    return try Data(contentsOf: url)
}

func jsonObjectTag(_ value: JSONValue?) -> String? {
    guard case let .object(object)? = value,
          case let .string(tag)? = object["tag"]
    else { return nil }
    return tag
}
