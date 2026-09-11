@testable import ArkhamHorrorShared
import Foundation
import Testing

enum AssignmentContinuationFixture: String, CaseIterable, Sendable {
    case remainingDamage
    case remainingHorror

    var questionFixture: String {
        switch self {
        case .remainingDamage: "question-enemy-attack-remaining-damage-assignment"
        case .remainingHorror: "question-enemy-attack-remaining-horror-assignment"
        }
    }

    var answerFixture: String {
        switch self {
        case .remainingDamage: "answer-enemy-attack-assign-remaining-damage"
        case .remainingHorror: "answer-enemy-attack-assign-remaining-horror"
        }
    }

    var assignmentKind: EnemyAttackAssignmentKind {
        switch self {
        case .remainingDamage: .damage
        case .remainingHorror: .horror
        }
    }

    var title: String {
        switch self {
        case .remainingDamage: "Assign 1 damage"
        case .remainingHorror: "Assign 1 horror"
        }
    }

    var schemaTitle: String {
        switch self {
        case .remainingDamage: "Assign the remaining 1 damage"
        case .remainingHorror: "Assign the remaining 1 horror"
        }
    }

    var schemaDefinition: String {
        switch self {
        case .remainingDamage: "enemyAttackRemainingDamageAssignmentQuestion"
        case .remainingHorror: "enemyAttackRemainingHorrorAssignmentQuestion"
        }
    }

    var systemImage: String {
        switch self {
        case .remainingDamage: "heart.slash.fill"
        case .remainingHorror: "brain.head.profile"
        }
    }

    var directAmounts: (damage: Int64, horror: Int64) {
        switch self {
        case .remainingDamage: (1, 0)
        case .remainingHorror: (0, 1)
        }
    }
}

extension DamageAssignmentFixtures {
    static let continuationQuestionVersion = 7

    static let continuationEnemyIdentityPaths = [
        "/source/contents",
        "/question/question/choices/0/messages/0/contents/contents/1/contents",
        "/question/question/choices/0/messages/1/contents/contents/1/contents",
    ]

    static let continuationInvestigatorIdentityPaths = [
        "/question/question/choices/0/component/investigatorId",
        "/question/question/choices/0/messages/0/contents/contents/0",
        "/question/question/choices/0/messages/1/contents/contents/0",
        "/question/question/choices/0/messages/1/contents/contents/6/0/contents",
        "/question/question/choices/0/messages/1/contents/contents/7/0/contents",
    ]

    static func contractData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    static func continuationValue(
        _ fixture: AssignmentContinuationFixture
    ) throws -> JSONValue {
        try ContractJSON.decode(
            JSONValue.self,
            from: contractData(fixture.questionFixture)
        )
    }

    @MainActor
    static func continuationPrompt(
        _ fixture: AssignmentContinuationFixture,
        value: JSONValue? = nil,
        phase: BasicChoiceActionPhase? = nil
    ) throws -> BasicChoicePromptPresentation {
        let rawValue = try value ?? continuationValue(fixture)
        let payload = try payload(rawValue)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: continuationQuestionVersion,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: phase,
            actionChoiceIndex: phase == nil ? nil : 0,
            serverFeedback: nil
        )
    }

    @MainActor
    static func expectContinuationFailClosed(_ raw: JSONValue) throws {
        let payload = try payload(raw)
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: continuationQuestionVersion,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        if case .updateRequired = prompt.question {} else {
            Issue.record("Expected the assignment continuation to require an update")
        }
        #expect(prompt.choices.isEmpty)
        let controller = BoardCommandController(projection: projection(), prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(!controller.activatePromptChoice(0))
    }

    static func continuationAnswer(
        _ fixture: AssignmentContinuationFixture
    ) throws -> Data {
        let published = try ContractJSON.decode(
            BasicChoiceAnswer.self,
            from: contractData(fixture.answerFixture)
        )
        return try ContractJSON.encode(published)
    }
}

@MainActor
@Suite("Enemy attack assignment continuations")
struct BasicChoiceAssignmentContinuationTests {
    @Test(
        "Governed continuations preserve source index, identity, presentation, and answer",
        arguments: AssignmentContinuationFixture.allCases
    )
    func fixturePresentationAndEncoding(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let raw = try DamageAssignmentFixtures.continuationValue(fixture)
        let prompt = try DamageAssignmentFixtures.continuationPrompt(fixture, value: raw)
        let question = try #require(prompt.question.supportedQuestion)
        #expect(prompt.identity.rawQuestion == raw)
        #expect(prompt.questionVersion == DamageAssignmentFixtures.continuationQuestionVersion)
        #expect(question.kind == .questionWithSource)
        #expect(question.choices.map(\.index) == [0])

        let choice = try #require(question.choices.first)
        #expect(choice.title == fixture.title)
        #expect(choice.systemImage == fixture.systemImage)
        guard case let .assignEnemyAttackDamage(assignment) = choice.content else {
            Issue.record("Expected the governed \(fixture.rawValue) assignment")
            return
        }
        #expect(assignment.kind == fixture.assignmentKind)
        #expect(assignment.enemyID == DamageAssignmentFixtures.enemyID)
        #expect(assignment.investigatorID == DamageAssignmentFixtures.investigatorID)

        guard case let .object(root) = raw,
              case let .object(labelQuestion)? = root["question"],
              case let .object(chooseOne)? = labelQuestion["question"],
              case let .array(rawChoices)? = chooseOne["choices"],
              case let .object(rawChoice) = rawChoices.first,
              case let .array(rawMessages)? = rawChoice["messages"]
        else { throw TestFailure() }
        #expect(labelQuestion["label"] == .string(fixture.title))
        #expect(assignment.messages == rawMessages)

        let projection = DamageAssignmentFixtures.projection()
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: choice,
            in: projection
        ) == "\(fixture.title) to Roland Banks")
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: choice,
            in: projection,
            canSubmit: true,
            statusMessage: nil
        ) == "Activates choice 1.")

        let answer = BasicChoiceAnswer(
            choice: choice.index,
            playerID: prompt.ownerID,
            questionVersion: prompt.questionVersion
        )
        let published = try DamageAssignmentFixtures.continuationAnswer(fixture)
        #expect(try ContractJSON.encode(answer) == published)
        try expectSchemaTitle(fixture)
    }

    @Test(
        "Projection identities gate both continuations and their accessibility hint",
        arguments: AssignmentContinuationFixture.allCases
    )
    func projectionIdentityActionability(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let prompt = try DamageAssignmentFixtures.continuationPrompt(fixture)
        let choice = try #require(prompt.choices.first)
        #expect(prompt.isChoiceActionable(choice, in: DamageAssignmentFixtures.projection()))
        for projection in [
            DamageAssignmentFixtures.projection(includeEnemy: false),
            DamageAssignmentFixtures.projection(includeInvestigator: false),
        ] {
            #expect(!prompt.isChoiceActionable(choice, in: projection))
            #expect(BoardDisplayFormatting.choiceAccessibilityHint(
                for: choice,
                in: projection,
                canSubmit: true,
                statusMessage: nil
            ) == "The enemy or investigator for this assignment isn't currently available.")
        }
    }

    @Test(
        "Controller jump, primary activation, and pending focus govern both continuations",
        arguments: AssignmentContinuationFixture.allCases
    )
    func controllerAndPendingFocus(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let raw = try DamageAssignmentFixtures.continuationValue(fixture)
        var submitted: [Int] = []
        var retries = 0
        let controller = try BoardCommandController(
            projection: DamageAssignmentFixtures.projection(),
            prompt: DamageAssignmentFixtures.continuationPrompt(fixture, value: raw),
            onChoice: { submitted.append($0) },
            onRetry: { retries += 1 }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])

        for phase in [BasicChoiceActionPhase.sending, .awaitingSnapshot, .uncertain] {
            try controller.applyPrompt(DamageAssignmentFixtures.continuationPrompt(
                fixture,
                value: raw,
                phase: phase
            ))
            #expect(!controller.activatePromptChoice(0))
            #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        }
        try controller.applyPrompt(DamageAssignmentFixtures.continuationPrompt(
            fixture,
            value: raw,
            phase: .retryable(.transportFailure)
        ))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(retries == 1)
    }

    private func expectSchemaTitle(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let schema = try JSONSerialization.jsonObject(
            with: DamageAssignmentFixtures.contractData(
                "basic-choice-question.schema"
            )
        ) as? [String: Any]
        let definitions = try #require(schema?["$defs"] as? [String: Any])
        let branch = try #require(definitions[fixture.schemaDefinition] as? [String: Any])
        let publishedTitle = try #require(branch["title"] as? String)
        #expect(fixture.schemaTitle == publishedTitle)
    }
}
