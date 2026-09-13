@testable import ArkhamHorrorShared
import Foundation
import Testing

enum EngageActionFixtures {
    struct Mutation {
        let operation: String
        let replacement: JSONValue?
        let pointer: String
    }

    static let enemyID = BoardTestFixtures.enemyID("000000000388")

    static func value() throws -> JSONValue {
        let url = try #require(Bundle.module.url(
            forResource: "question-player-window-engage-action",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try ContractJSON.decode(JSONValue.self, from: Data(contentsOf: url))
    }

    static func payload(_ value: JSONValue? = nil) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(value ?? self.value())
        )
    }

    static func prompt(_ value: JSONValue? = nil) throws -> BasicChoicePromptPresentation {
        let payload = try payload(value)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 22,
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
    }

    static func projection(includeEnemy: Bool = true) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            enemyValues: includeEnemy ? [enemyID: .null] : [:]
        ))
    }
}

@MainActor
@Suite("Enemy Engage choice")
struct BasicChoiceEngageActionTests {
    @Test("Engage retains its authoritative identity, source index, and opaque data")
    func governedEngageParsesLosslessly() throws {
        let raw = try EngageActionFixtures.value()
        let payload = try EngageActionFixtures.payload(raw)
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .playerWindowChooseOne)
        #expect(question.choices.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(question.choices.map(\.title) == [
            "Gain a resource", "Draw a card", "End turn", "Investigate", "Fight", "Engage",
        ])
        #expect(question.choices[5].systemImage == "person.2.fill")

        guard case let .engage(engageAbility, enemyID) = question.choices[5].content
        else {
            Issue.record("Expected governed Engage choice")
            return
        }
        #expect(enemyID == EngageActionFixtures.enemyID)
        #expect(engageAbility.investigatorID.rawValue.rawValue == "c01001")
        #expect(engageAbility.cardCode.rawValue == "c01160")
        #expect(engageAbility.windows.count == 3)
        #expect(engageAbility.before.isEmpty)
        #expect(engageAbility.messages.isEmpty)
        #expect(question.choices[5].ability == engageAbility)

        guard case let .object(root) = raw,
              case let .array(rawChoices)? = root["choices"],
              case let .object(rawEngage) = rawChoices[5],
              case let .object(rawAbility)? = rawEngage["ability"]
        else { throw TestFailure() }
        #expect(rawAbility["index"] == .number(.integer(102)))
        #expect(rawAbility["criteria"] != nil)
        #expect(rawAbility["requestor"] != nil)
        #expect(rawAbility["triggersSkillTest"] == .bool(false))
        #expect(rawAbility["type"] != nil)
        #expect(engageAbility.rawAbility == rawEngage["ability"])
        #expect(try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(payload)
        ) == raw)
    }

    @Test("Engage and ability windows fail closed when governed fields are malformed")
    func malformedEngageFieldsFailClosed() throws {
        let canonical = try EngageActionFixtures.value()
        let mutations = [
            EngageActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("Parley"),
                pointer: "/choices/5/ability/type/actions/contents"
            ),
            EngageActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("LocationSource"),
                pointer: "/choices/5/ability/source/tag"
            ),
            EngageActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("00000000-0000-0000-0000-00000000038A"),
                pointer: "/choices/5/ability/source/contents"
            ),
            EngageActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("not-an-object"),
                pointer: "/choices/5/windows/0"
            ),
        ]
        for mutation in mutations {
            let mutated = try EnemyAttackFixtures.applying(
                operation: mutation.operation,
                path: mutation.pointer.split(separator: "/"),
                replacement: mutation.replacement,
                to: canonical
            )
            let question = try #require(
                EngageActionFixtures.payload(mutated).supportedQuestion
            )
            #expect(!question.choices[5].isSupported)
            #expect(question.choices[5].title == "Update required")
        }
    }

    @Test("Engage actionability and controller routing follow the referenced enemy")
    func enemyPresenceControlsActionabilityAndRouting() throws {
        let prompt = try EngageActionFixtures.prompt()
        let engage = prompt.choices[5]
        let present = EngageActionFixtures.projection()
        let absent = EngageActionFixtures.projection(includeEnemy: false)

        #expect(prompt.isChoiceActionable(engage, in: present))
        #expect(!prompt.isChoiceActionable(engage, in: absent))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: engage, in: present
        ) == "Engage")
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: engage,
            in: absent,
            canSubmit: true,
            statusMessage: nil
        ) == "This enemy isn't currently available.")

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: present,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(5)))
        #expect(controller.handle(
            focusID: BoardFocusID.promptChoice(5),
            .command(.primaryAction)
        ))
        #expect(submitted == [5])

        controller.applySnapshot(absent, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(5)))
        #expect(!controller.activatePromptChoice(5))
    }
}

extension AppModelLiveGameTests {
    @Test("Engage submits its exact source index with the authoritative question version")
    func engageSubmitsExactVersionedAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let base = try loadGetGame()
        let envelope = try engageActionEnvelope(
            base, question: EngageActionFixtures.value(), questionVersion: 22
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let presentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(presentation.questionVersion == 22)
        let engage = try #require(presentation.choices.first { $0.index == 5 })
        #expect(try presentation.isChoiceActionable(
            engage,
            in: #require(model.liveGameStates[gameID]?.lastKnownProjection)
        ))
        #expect(
            await model.submitBasicChoice(presentation.identity, choiceIndex: 5)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData == [
            engageActionAnswer(identity: presentation.identity),
        ])
    }

    @Test("An older Engage prompt cannot submit after a newer authoritative snapshot")
    func staleEngagePromptFailsClosed() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let base = try loadGetGame()
        let question = try EngageActionFixtures.value()
        let envelope = try engageActionEnvelope(
            base, question: question, questionVersion: 22
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let staleIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let update = try snapshotUpdate(
            from: envelope,
            scenarioSteps: 23,
            replacingQuestionWith: question
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == 23)
        #expect(current.identity != staleIdentity)
        #expect(
            await model.submitBasicChoice(staleIdentity, choiceIndex: 5) == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("A failed Engage send retries only against the current connection identity")
    func engageRetryReconcilesConnectionIdentity() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let base = try loadGetGame()
        let envelope = try engageActionEnvelope(
            base, question: EngageActionFixtures.value(), questionVersion: 22
        )
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: firstConnection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 5) == .retryableFailure
        )

        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await firstConnection.enqueue(.failure(GameSocketTransportError()))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != oldIdentity)
        #expect(current.actionPhase == .retryable(.transportFailure))

        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await firstConnection.sentData == [
            engageActionAnswer(identity: oldIdentity),
        ])
        #expect(await replacement.sentData == [
            engageActionAnswer(identity: current.identity),
        ])
    }

    private func engageActionEnvelope(
        _ base: GetGameEnvelope,
        question: JSONValue,
        questionVersion: Int
    ) throws -> GetGameEnvelope {
        let withQuestion = try envelopeReplacingQuestion(
            base,
            scenarioSteps: questionVersion,
            replacingQuestionWith: question
        )
        let raw = try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(withQuestion)
        )
        let enemyID = EngageActionFixtures.enemyID.rawValue.uuidString.lowercased()
        let withEnemy = try EnemyAttackFixtures.applying(
            operation: "add",
            path: ["game", "enemies", Substring(enemyID)],
            replacement: .null,
            to: raw
        )
        return try ContractJSON.decode(
            GetGameEnvelope.self, from: ContractJSON.encode(withEnemy)
        )
    }

    private func engageActionAnswer(identity: BasicChoicePromptIdentity) -> Data {
        Data(
            """
            {"contents":{"choice":5,\
            "playerId":"\(identity.ownerID.rawValue.uuidString.lowercased())",\
            "questionVersion":\(identity.questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }
}
