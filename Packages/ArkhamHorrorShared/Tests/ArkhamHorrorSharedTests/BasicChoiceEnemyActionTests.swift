@testable import ArkhamHorrorShared
import Foundation
import Testing

enum EnemyActionFixtures {
    struct Mutation {
        let operation: String
        let replacement: JSONValue?
        let pointer: String
    }

    static let enemyID = BoardTestFixtures.enemyID("000000000388")

    static func value() throws -> JSONValue {
        let url = try #require(Bundle.module.url(
            forResource: "question-player-window-enemy-actions",
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

    static func prompt(
        _ value: JSONValue? = nil,
        phase: BasicChoiceActionPhase? = nil,
        actionChoiceIndex: Int? = nil
    ) throws -> BasicChoicePromptPresentation {
        let payload = try payload(value)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 16,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: phase,
            actionChoiceIndex: actionChoiceIndex,
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
@Suite("Enemy Fight and Evade choices")
struct BasicChoiceEnemyActionTests {
    @Test("Fight and Evade retain authoritative identities, source indices, and opaque data")
    func governedActionsParseLosslessly() throws {
        let raw = try EnemyActionFixtures.value()
        let payload = try EnemyActionFixtures.payload(raw)
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .playerWindowChooseOne)
        #expect(question.choices.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(question.choices.map(\.title) == [
            "Gain a resource", "Draw a card", "End turn", "Investigate", "Fight", "Evade",
        ])
        #expect(question.choices[4].systemImage == "burst.fill")
        #expect(question.choices[5].systemImage == "figure.run")

        guard case let .fight(fightAbility, fightEnemyID) = question.choices[4].content,
              case let .evade(evadeAbility, evadeEnemyID) = question.choices[5].content
        else {
            Issue.record("Expected governed Fight and Evade choices")
            return
        }
        #expect(fightEnemyID == EnemyActionFixtures.enemyID)
        #expect(evadeEnemyID == EnemyActionFixtures.enemyID)
        #expect(fightAbility.investigatorID.rawValue.rawValue == "c01001")
        #expect(evadeAbility.investigatorID.rawValue.rawValue == "c01001")
        #expect(fightAbility.cardCode.rawValue == "c01160")
        #expect(evadeAbility.cardCode.rawValue == "c01160")
        #expect(fightAbility.windows.count == 3)
        #expect(fightAbility.before.isEmpty)
        #expect(fightAbility.messages.isEmpty)
        #expect(question.choices[4].ability == fightAbility)
        #expect(question.choices[5].ability == evadeAbility)

        guard case let .object(root) = raw,
              case let .array(rawChoices)? = root["choices"],
              case let .object(rawFight) = rawChoices[4],
              case let .object(rawEvade) = rawChoices[5],
              case let .object(rawFightAbility)? = rawFight["ability"],
              case let .object(rawEvadeAbility)? = rawEvade["ability"]
        else { throw TestFailure() }
        #expect(rawFightAbility["criteria"] != nil)
        #expect(rawFightAbility["requestor"] != nil)
        #expect(rawEvadeAbility["criteria"] != nil)
        #expect(rawEvadeAbility["requestor"] != nil)
        #expect(fightAbility.rawAbility == rawFight["ability"])
        #expect(evadeAbility.rawAbility == rawEvade["ability"])
        #expect(try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(payload)
        ) == raw)
    }

    @Test("Fight and Evade require a canonical exact EnemySource")
    func malformedSourcesFailClosed() throws {
        let canonical = try EnemyActionFixtures.value()
        let mutations = [
            EnemyActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("LocationSource"),
                pointer: "/choices/4/ability/source/tag"
            ),
            EnemyActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("00000000-0000-0000-0000-00000000038X"),
                pointer: "/choices/4/ability/source/contents"
            ),
            EnemyActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("AAAAAAAA-0000-0000-0000-000000000388"),
                pointer: "/choices/5/ability/source/contents"
            ),
            EnemyActionFixtures.Mutation(
                operation: "add",
                replacement: .bool(true),
                pointer: "/choices/5/ability/source/extra"
            ),
            EnemyActionFixtures.Mutation(
                operation: "remove",
                replacement: nil,
                pointer: "/choices/4/ability/source"
            ),
            EnemyActionFixtures.Mutation(
                operation: "replace",
                replacement: .string("Teleport"),
                pointer: "/choices/5/ability/type/actions/contents"
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
                EnemyActionFixtures.payload(mutated).supportedQuestion
            )
            let index = mutation.pointer.contains("/choices/4/") ? 4 : 5
            #expect(!question.choices[index].isSupported)
            #expect(question.choices[index].title == "Update required")
        }
    }

    @Test("Fight and Evade actionability follows the referenced enemy")
    func enemyPresenceControlsActionability() throws {
        let prompt = try EnemyActionFixtures.prompt()
        let choices = prompt.choices
        let present = EnemyActionFixtures.projection()
        let absent = EnemyActionFixtures.projection(includeEnemy: false)

        for index in [4, 5] {
            #expect(prompt.isChoiceActionable(choices[index], in: present))
            #expect(!prompt.isChoiceActionable(choices[index], in: absent))
            #expect(BoardDisplayFormatting.choiceDisplayTitle(
                for: choices[index], in: present
            ) == choices[index].title)
            #expect(BoardDisplayFormatting.choiceAccessibilityHint(
                for: choices[index],
                in: absent,
                canSubmit: true,
                statusMessage: nil
            ) == "This enemy isn't currently available.")
        }
    }

    @Test("Semantic primary action preserves Fight and Evade source indices")
    func controllerPreservesSourceIndices() throws {
        let prompt = try EnemyActionFixtures.prompt()
        let projection = EnemyActionFixtures.projection()

        for index in [4, 5] {
            var submitted: [Int] = []
            let controller = BoardCommandController(
                projection: projection,
                prompt: prompt,
                onChoice: { submitted.append($0) }
            )
            #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(index)))
            #expect(controller.handle(
                focusID: BoardFocusID.promptChoice(index),
                .command(.primaryAction)
            ))
            #expect(submitted == [index])
        }

        let controller = BoardCommandController(projection: projection, prompt: prompt)
        controller.applySnapshot(
            EnemyActionFixtures.projection(includeEnemy: false),
            prompt: prompt
        )
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(4)))
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(5)))
        #expect(!controller.activatePromptChoice(4))
        #expect(!controller.activatePromptChoice(5))
    }
}

extension AppModelLiveGameTests {
    @Test("Fight and Evade submit exact source indices with the authoritative question version")
    func enemyActionsSubmitExactVersionedAnswers() async throws {
        for index in [4, 5] {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let base = try loadGetGame()
            let envelope = try enemyActionEnvelope(
                base, question: EnemyActionFixtures.value(), questionVersion: 16
            )
            let connection = FakeGameSocketConnection()
            await connection.enqueueSendResult(.success(()))
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let presentation = try #require(model.basicChoicePresentation(for: gameID))
            #expect(presentation.questionVersion == 16)
            #expect(try presentation.isChoiceActionable(
                #require(presentation.choices.first { $0.index == index }),
                in: #require(model.liveGameStates[gameID]?.lastKnownProjection)
            ))
            #expect(
                await model.submitBasicChoice(presentation.identity, choiceIndex: index)
                    == .sentAwaitingSnapshot
            )
            #expect(await connection.sentData == [
                enemyActionAnswer(identity: presentation.identity, choiceIndex: index),
            ])
        }
    }

    @Test("A failed Fight send retries only against the current connection identity")
    func fightRetryReconcilesConnectionIdentity() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let base = try loadGetGame()
        let envelope = try enemyActionEnvelope(
            base, question: EnemyActionFixtures.value(), questionVersion: 16
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
            await model.submitBasicChoice(oldIdentity, choiceIndex: 4) == .retryableFailure
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
            enemyActionAnswer(identity: oldIdentity, choiceIndex: 4),
        ])
        #expect(await replacement.sentData == [
            enemyActionAnswer(identity: current.identity, choiceIndex: 4),
        ])
    }

    private func enemyActionEnvelope(
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
        let enemyID = EnemyActionFixtures.enemyID.rawValue.uuidString.lowercased()
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

    private func enemyActionAnswer(
        identity: BasicChoicePromptIdentity,
        choiceIndex: Int
    ) -> Data {
        Data(
            """
            {"contents":{"choice":\(choiceIndex),\
            "playerId":"\(identity.ownerID.rawValue.uuidString.lowercased())",\
            "questionVersion":\(identity.questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }
}
