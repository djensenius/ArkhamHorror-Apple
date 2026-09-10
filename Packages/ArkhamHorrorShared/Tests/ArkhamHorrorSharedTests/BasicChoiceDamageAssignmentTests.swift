@testable import ArkhamHorrorShared
import Foundation
import Testing

enum DamageAssignmentFixtures {
    static let enemyID = BoardTestFixtures.enemyID("000000000388")
    static let investigatorID = BoardTestFixtures.investigatorID("c01001")

    static let enemyIdentityPaths = [
        "/source/contents",
        "/question/question/choices/0/messages/0/contents/contents/1/contents",
        "/question/question/choices/0/messages/1/contents/contents/1/contents",
        "/question/question/choices/1/messages/0/contents/contents/1/contents",
        "/question/question/choices/1/messages/1/contents/contents/1/contents",
    ]

    static let investigatorIdentityPaths = [
        "/question/question/choices/0/component/investigatorId",
        "/question/question/choices/0/messages/0/contents/contents/0",
        "/question/question/choices/0/messages/1/contents/contents/0",
        "/question/question/choices/0/messages/1/contents/contents/6/0/contents",
        "/question/question/choices/1/component/investigatorId",
        "/question/question/choices/1/messages/0/contents/contents/0",
        "/question/question/choices/1/messages/1/contents/contents/0",
        "/question/question/choices/1/messages/1/contents/contents/7/0/contents",
    ]

    static func data(_ name: String = "question-enemy-attack-damage-assignment") throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    static func value() throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: data())
    }

    static func payload(_ value: JSONValue) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: ContractJSON.encode(value))
    }

    static func prompt(
        _ value: JSONValue,
        phase: BasicChoiceActionPhase? = nil,
        actionChoiceIndex: Int = 0
    ) throws -> BasicChoicePromptPresentation {
        let payload = try payload(value)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 6,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: phase,
            actionChoiceIndex: phase == nil ? nil : actionChoiceIndex,
            serverFeedback: nil
        )
    }

    static func projection(
        includeEnemy: Bool = true,
        includeInvestigator: Bool = true,
        enemyID: EnemyID = enemyID,
        investigatorID: InvestigatorID = investigatorID
    ) -> BoardProjection {
        let investigators: [InvestigatorID: Investigator] = includeInvestigator
            ? [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: "The Fed")
                ),
            ]
            : [:]
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: investigators,
            playerOrder: includeInvestigator ? [investigatorID] : [],
            enemyValues: includeEnemy ? [enemyID: .null] : [:]
        ))
    }
}

@MainActor
@Suite("Enemy attack damage assignment")
struct BasicChoiceDamageAssignmentTests {
    @Test("The governed prompt exposes both semantic source choices and exact answers")
    func fixturePresentationAndEncoding() throws {
        let raw = try DamageAssignmentFixtures.value()
        let prompt = try DamageAssignmentFixtures.prompt(raw)
        let question = try #require(prompt.question.supportedQuestion)
        #expect(question.kind == .questionWithSource)
        #expect(question.choices.map(\.index) == [0, 1])
        #expect(question.choices.map(\.title) == ["Assign 1 damage", "Assign 1 horror"])
        #expect(question.choices.map(\.systemImage) == ["heart.slash.fill", "brain.head.profile"])

        guard case let .object(root) = raw,
              case let .object(labelQuestion)? = root["question"],
              case let .object(chooseOne)? = labelQuestion["question"],
              case let .array(rawChoices)? = chooseOne["choices"]
        else { throw TestFailure() }
        try DamageAssignmentAssertions.expectPublishedQuestionTitle(labelQuestion["label"])
        try DamageAssignmentAssertions.expectSemanticAssignments(
            question: question, rawChoices: rawChoices
        )
        let projection = DamageAssignmentFixtures.projection()
        DamageAssignmentAssertions.expectPresentation(prompt: prompt, projection: projection)

        #expect(try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(DamageAssignmentFixtures.payload(raw))
        ) == raw)
        try DamageAssignmentAssertions.expectPublishedAnswer(
            question.choices[0],
            prompt: prompt,
            fixture: "answer-enemy-attack-assign-damage"
        )
        try DamageAssignmentAssertions.expectPublishedAnswer(
            question.choices[1],
            prompt: prompt,
            fixture: "answer-enemy-attack-assign-horror"
        )
    }

    @Test("All 114 backend-published assignment mutations fail closed")
    func governedMutationsFailClosed() throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self, from: DamageAssignmentFixtures.data("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }
        let fixturePath = JSONValue.string(
            "contracts/fixtures/question-enemy-attack-damage-assignment.json"
        )
        var checked = 0
        for case let .object(entry) in negatives where entry["basePositiveFixture"] == fixturePath {
            guard case let .string(base)? = entry["basePointer"],
                  case let .object(mutation)? = entry["mutation"],
                  case let .string(pointer)? = mutation["pointer"],
                  case let .string(operation)? = mutation["op"]
            else { throw TestFailure() }
            let mutated = try EnemyAttackFixtures.applying(
                operation: operation,
                path: (base + pointer).split(separator: "/"),
                replacement: mutation["value"],
                to: DamageAssignmentFixtures.value()
            )
            try DamageAssignmentAssertions.expectFailClosed(mutated)
            checked += 1
        }
        #expect(checked == 114)
    }

    @Test("Every repeated source and investigator identity must agree")
    func repeatedIdentitiesMustMatch() throws {
        let alternateEnemy = JSONValue.string(
            BoardTestFixtures.enemyID("000000000389").codingKey.stringValue
        )
        for path in DamageAssignmentFixtures.enemyIdentityPaths {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: alternateEnemy,
                to: DamageAssignmentFixtures.value()
            )
            try DamageAssignmentAssertions.expectFailClosed(mutated)
        }
        for path in DamageAssignmentFixtures.investigatorIdentityPaths {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string("c01002"),
                to: DamageAssignmentFixtures.value()
            )
            try DamageAssignmentAssertions.expectFailClosed(mutated)
        }
    }

    @Test("Consistently rebound valid identities remain semantic rather than fixture-specific")
    func consistentlyReboundIdentitiesParse() throws {
        let alternateEnemy = BoardTestFixtures.enemyID("000000000389")
        let alternateInvestigator = BoardTestFixtures.investigatorID("c01002")
        var rebound = try DamageAssignmentFixtures.value()
        for path in DamageAssignmentFixtures.enemyIdentityPaths {
            rebound = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string(alternateEnemy.codingKey.stringValue),
                to: rebound
            )
        }
        for path in DamageAssignmentFixtures.investigatorIdentityPaths {
            rebound = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string(alternateInvestigator.codingKey.stringValue),
                to: rebound
            )
        }

        let prompt = try DamageAssignmentFixtures.prompt(rebound)
        let question = try #require(prompt.question.supportedQuestion)
        #expect(question.choices.allSatisfy {
            guard case let .assignEnemyAttackDamage(assignment) = $0.content else {
                return false
            }
            return assignment.enemyID == alternateEnemy
                && assignment.investigatorID == alternateInvestigator
        })
        let projection = DamageAssignmentFixtures.projection(
            enemyID: alternateEnemy,
            investigatorID: alternateInvestigator
        )
        #expect(question.choices.allSatisfy { projection.isChoiceActionable($0) })
    }

    @Test("Numerically equal noncanonical integer spellings do not gain authority")
    func numericSpellingsFailClosed() throws {
        let directDamage =
            "/question/question/choices/0/messages/0/contents/contents/2"
        let directHorror =
            "/question/question/choices/0/messages/0/contents/contents/3"
        let cases = [(directDamage, "1.0"), (directDamage, "1e0"), (directHorror, "-0")]
        for (path, token) in cases {
            let replacement = try ContractJSON.decode(JSONValue.self, from: Data(token.utf8))
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: replacement,
                to: DamageAssignmentFixtures.value()
            )
            try DamageAssignmentAssertions.expectFailClosed(mutated)
        }
    }

    @Test("Generic and reordered wrapper forms remain unsupported")
    func wrapperBoundaryFailsClosed() throws {
        let canonical = try DamageAssignmentFixtures.value()
        guard case let .object(root) = canonical,
              case let .object(labelQuestion)? = root["question"],
              let chooseOne = labelQuestion["question"]
        else { throw TestFailure() }

        let genericPayload = try DamageAssignmentFixtures.payload(chooseOne)
        let genericQuestion = try #require(genericPayload.supportedQuestion)
        #expect(genericQuestion.kind == .chooseOne)
        #expect(genericQuestion.choices.map(\.index) == [0, 1])
        #expect(genericQuestion.choices.allSatisfy { !$0.isSupported })

        var withoutLabel = root
        withoutLabel["question"] = chooseOne
        try DamageAssignmentAssertions.expectFailClosed(.object(withoutLabel))
    }

    @Test("Actionability and labels require both current projection identities")
    func projectionIdentityActionability() throws {
        let prompt = try DamageAssignmentFixtures.prompt(DamageAssignmentFixtures.value())
        let present = DamageAssignmentFixtures.projection()
        #expect(prompt.choices.allSatisfy { present.isChoiceActionable($0) })
        for projection in [
            DamageAssignmentFixtures.projection(includeEnemy: false),
            DamageAssignmentFixtures.projection(includeInvestigator: false),
        ] {
            #expect(prompt.choices.allSatisfy { !projection.isChoiceActionable($0) })
            #expect(prompt.choices.allSatisfy {
                BoardDisplayFormatting.choiceAccessibilityHint(
                    for: $0, in: projection, canSubmit: true, statusMessage: nil
                )
                    == "The enemy or investigator for this assignment isn't currently available."
            })
        }
    }

    @Test("Controller focus preserves both source indices and pending retry semantics")
    func controllerAndPendingFocus() throws {
        let raw = try DamageAssignmentFixtures.value()
        let projection = DamageAssignmentFixtures.projection()
        var submitted: [Int] = []
        var retries = 0
        let controller = try BoardCommandController(
            projection: projection,
            prompt: DamageAssignmentFixtures.prompt(raw),
            onChoice: { submitted.append($0) },
            onRetry: { retries += 1 }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(controller.handle(.command(.focusMove(.down))))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(1))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0, 1])

        for phase in [BasicChoiceActionPhase.sending, .awaitingSnapshot, .uncertain] {
            try controller.applyPrompt(DamageAssignmentFixtures.prompt(
                raw, phase: phase, actionChoiceIndex: 1
            ))
            #expect(!controller.activatePromptChoice(0))
            #expect(!controller.activatePromptChoice(1))
            #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
            #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        }
        try controller.applyPrompt(DamageAssignmentFixtures.prompt(
            raw, phase: .retryable(.transportFailure), actionChoiceIndex: 1
        ))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(retries == 1)
    }
}

@MainActor
private enum DamageAssignmentAssertions {
    static func expectSemanticAssignments(
        question: BasicChoiceQuestion,
        rawChoices: [JSONValue]
    ) throws {
        let kinds: [EnemyAttackAssignmentKind] = [.damage, .horror]
        for (index, expectedKind) in kinds.enumerated() {
            let choice = question.choices[index]
            guard case let .assignEnemyAttackDamage(assignment) = choice.content else {
                Issue.record("Expected the governed damage assignment at source index \(index)")
                continue
            }
            #expect(assignment.kind == expectedKind)
            #expect(assignment.enemyID == DamageAssignmentFixtures.enemyID)
            #expect(assignment.investigatorID == DamageAssignmentFixtures.investigatorID)
            guard case let .object(rawChoice) = rawChoices[index],
                  case let .array(rawMessages)? = rawChoice["messages"]
            else { throw TestFailure() }
            #expect(assignment.messages == rawMessages)
        }
    }

    static func expectPresentation(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) {
        #expect(prompt.choices.allSatisfy { prompt.isChoiceActionable($0, in: projection) })
        #expect(prompt.choices.map {
            BoardDisplayFormatting.choiceDisplayTitle(for: $0, in: projection)
        } == [
            "Assign 1 damage to Roland Banks",
            "Assign 1 horror to Roland Banks",
        ])
        #expect(prompt.choices.map {
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: $0, in: projection, canSubmit: true, statusMessage: nil
            )
        } == ["Activates choice 1.", "Activates choice 2."])
    }

    static func expectFailClosed(_ raw: JSONValue) throws {
        let prompt = try DamageAssignmentFixtures.prompt(raw)
        let projection = DamageAssignmentFixtures.projection()
        if case .updateRequired = prompt.question {} else {
            Issue.record("Expected the assignment root to require an update")
        }
        #expect(prompt.choices.isEmpty)
        let controller = BoardCommandController(projection: projection, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(!controller.activatePromptChoice(0))
        #expect(!controller.activatePromptChoice(1))
    }

    static func expectPublishedQuestionTitle(_ rawTitle: JSONValue?) throws {
        let schema = try JSONSerialization.jsonObject(
            with: DamageAssignmentFixtures.data("basic-choice-question.schema")
        ) as? [String: Any]
        let definitions = try #require(schema?["$defs"] as? [String: Any])
        let branch = try #require(
            definitions["enemyAttackDamageAssignmentQuestion"] as? [String: Any]
        )
        #expect(try rawTitle == .string(#require(branch["title"] as? String)))
    }

    static func expectPublishedAnswer(
        _ choice: BasicChoice,
        prompt: BasicChoicePromptPresentation,
        fixture: String
    ) throws {
        let answer = BasicChoiceAnswer(
            choice: choice.index, playerID: prompt.ownerID, questionVersion: 6
        )
        let published = try ContractJSON.decode(
            BasicChoiceAnswer.self,
            from: DamageAssignmentFixtures.data(fixture)
        )
        #expect(answer == published)
        #expect(try ContractJSON.encode(answer) == ContractJSON.encode(published))
    }
}
