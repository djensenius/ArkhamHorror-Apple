// swiftlint:disable file_length function_body_length type_body_length line_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Amount answer encoders match the vendored contract fixtures")
    func amountAnswerEncodingMatchesFixtures() throws {
        let playerID = BoardTestFixtures.playerID("000000000001")
        try expectCanonicalFixture(
            "answer-amounts",
            encodes: AmountsAnswer(
                amounts: ["00000000-0000-0000-0000-000000000011": 1],
                playerID: playerID,
                questionVersion: 42
            )
        )
        try expectCanonicalFixture(
            "answer-payment-amounts",
            encodes: PaymentAmountsAnswer(
                amounts: ["00000000-0000-0000-0000-000000000010": 2],
                playerID: playerID,
                questionVersion: 42
            )
        )
        try expectCanonicalFixture(
            "answer-exchange-amounts",
            encodes: ExchangeAmountsAnswer(
                source: .object(["tag": .string("GameSource")]),
                fromInvestigator: "c01001",
                toInvestigator: "c02002",
                token: "Resource",
                amount: 2
            )
        )
    }

    @Test("ChooseAmounts is model-renderable, fenced, and sends exact bytes")
    func chooseAmountsSendsExactBytes() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 207
        )
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.readOnlyReason == nil)
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.requiresDedicatedAmountUI)
        #expect(prompt.canSubmit)

        let amounts = ["00000000-0000-0000-0000-000000000065": 1]
        let first = Task { await model.submitAmountsAnswer(prompt.identity, amounts: amounts) }
        await connection.waitUntilSendPending(1)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
        #expect(await model.submitAmountsAnswer(prompt.identity, amounts: amounts) == .alreadyPending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        #expect(try await connection.sentData == [amountAnswerBytes(amounts: amounts, version: 207)])
    }

    @Test("ChoosePaymentAmounts sends exact bytes and null target imposes no total constraint")
    func paymentAmountsSendsExactBytesIncludingNullTarget() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try amountEnvelope(
            rawQuestion: paymentRawQuestion(
                choiceID: "00000000-0000-0000-0000-00000000004d",
                min: 0,
                max: 3,
                target: .null
            ),
            presentation: representativePresentation(named: "choosePaymentAmounts-null-target"),
            questionVersion: 310
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.readOnlyReason == nil)
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.requiresDedicatedAmountUI)
        let amounts = ["00000000-0000-0000-0000-00000000004d": 3]

        #expect(
            await model.submitPaymentAmountsAnswer(prompt.identity, amounts: amounts)
                == .sentAwaitingSnapshot
        )
        #expect(try await connection.sentData == [paymentAmountAnswerBytes(amounts: amounts, version: 310)])
    }

    @Test("ChooseExchangeAmounts sends exact bytes and allows the web-compatible zero move")
    func exchangeAmountsSendsExactBytes() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try exchangeEnvelope(fromInitialAmount: 2, toInitialAmount: 1)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.readOnlyReason == nil)
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.requiresDedicatedAmountUI)
        #expect(await model.submitExchangeAmountsAnswer(prompt.identity, amount: 2) == .sentAwaitingSnapshot)
        #expect(try await connection.sentData == [exchangeAnswerBytes(amount: 2)])

        let (zeroModel, zeroFakes) = makeSignedInModel()
        await zeroModel.flowTask?.value
        makeModern(zeroModel)
        let zeroEnvelope = try exchangeEnvelope(fromInitialAmount: 2, toInitialAmount: 1)
        let zeroConnection = FakeGameSocketConnection()
        await zeroConnection.enqueueSendResult(.success(()))
        let zeroGameID = await startChoiceSession(
            model: zeroModel, fakes: zeroFakes, envelope: zeroEnvelope, connection: zeroConnection
        )
        let zeroPrompt = try #require(zeroModel.basicChoicePresentation(for: zeroGameID))
        #expect(await zeroModel.submitExchangeAmountsAnswer(zeroPrompt.identity, amount: 0) == .sentAwaitingSnapshot)
        #expect(try await zeroConnection.sentData == [exchangeAnswerBytes(amount: 0)])
    }

    @Test("Illegal amount allocations are refused without sending")
    func illegalAmountAllocationsAreRefused() async throws {
        let choices: [[String: JSONValue]] = [
            amountChoice("00000000-0000-0000-0000-0000000000a1", min: 0, max: 2),
            amountChoice("00000000-0000-0000-0000-0000000000a2", min: 0, max: 2),
        ]
        let cases: [(QuestionPresentation.AmountTarget, [String: Int], String)] = [
            (.total(2), ["00000000-0000-0000-0000-0000000000a1": 1], "missing choice"),
            (
                .total(2),
                [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 1,
                    "00000000-0000-0000-0000-0000000000ff": 0,
                ],
                "extra choice"
            ),
            (
                .total(2),
                [
                    "00000000-0000-0000-0000-0000000000a1": -1,
                    "00000000-0000-0000-0000-0000000000a2": 3,
                ],
                "bounds"
            ),
            (
                .min(2),
                [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 0,
                ],
                "min target"
            ),
            (
                .max(1),
                [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 1,
                ],
                "max target"
            ),
            (
                .total(2),
                [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 0,
                ],
                "total target"
            ),
            (
                .oneOf([1, 3]),
                [
                    "00000000-0000-0000-0000-0000000000a1": 2,
                    "00000000-0000-0000-0000-0000000000a2": 0,
                ],
                "one-of target"
            ),
        ]
        for (target, amounts, label) in cases {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try amountEnvelope(
                rawQuestion: chooseAmountsRawQuestion(choices: choices, target: target),
                presentation: chooseAmountsPresentation(choices: choices, target: target, questionVersion: 411),
                questionVersion: 411
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(model.basicChoicePresentation(for: gameID), "\(label)")
            #expect(await model.submitAmountsAnswer(prompt.identity, amounts: amounts) == .unsupportedChoice, "\(label)")
            #expect(await connection.sentData.isEmpty, "\(label)")
        }
    }

    @Test("Illegal payment and exchange allocations are refused without sending")
    func illegalPaymentAndExchangeAllocationsAreRefused() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let paymentEnvelope = try semanticEnvelope(
            rawFixture: "question-generic-payment-amounts",
            presentationFixture: "question-presentation-generic-payment-amounts",
            questionVersion: 208
        )
        let paymentConnection = FakeGameSocketConnection()
        let paymentGameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: paymentEnvelope, connection: paymentConnection
        )
        let paymentPrompt = try #require(model.basicChoicePresentation(for: paymentGameID))
        #expect(
            await model.submitPaymentAmountsAnswer(
                paymentPrompt.identity,
                amounts: ["00000000-0000-0000-0000-000000000066": 1]
            ) == .unsupportedChoice
        )
        #expect(await paymentConnection.sentData.isEmpty)

        let (exchangeModel, exchangeFakes) = makeSignedInModel()
        await exchangeModel.flowTask?.value
        makeModern(exchangeModel)
        let exchangeEnvelope = try exchangeEnvelope(fromInitialAmount: 1, toInitialAmount: 1)
        let exchangeConnection = FakeGameSocketConnection()
        let exchangeGameID = await startChoiceSession(
            model: exchangeModel,
            fakes: exchangeFakes,
            envelope: exchangeEnvelope,
            connection: exchangeConnection
        )
        let exchangePrompt = try #require(exchangeModel.basicChoicePresentation(for: exchangeGameID))
        #expect(await exchangeModel.submitExchangeAmountsAnswer(exchangePrompt.identity, amount: 2) == .unsupportedChoice)
        #expect(await exchangeModel.submitExchangeAmountsAnswer(exchangePrompt.identity, amount: -2) == .unsupportedChoice)
        #expect(await exchangeConnection.sentData.isEmpty)
    }

    @Test("Unsupported wrappers remain update-required and cannot send amount answers")
    func unsupportedAmountWrappersAreRefused() async throws {
        let wrappers: [(String, String, String)] = [
            ("amounts in PayCostQuestion", "question-generic-choose-amounts", "question-presentation-generic-choose-amounts"),
            ("payment in QuestionLabel", "question-generic-payment-amounts", "question-presentation-generic-payment-amounts"),
        ]
        for (label, rawFixture, presentationFixture) in wrappers {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try semanticEnvelope(
                rawFixture: rawFixture,
                presentationFixture: presentationFixture,
                questionVersion: 515,
                mutateRawQuestion: { rawQuestion in
                    if rawFixture.contains("choose-amounts") {
                        rawQuestion = payCostWrapped(rawQuestion)
                    } else {
                        rawQuestion = questionLabelWrapped(rawQuestion)
                    }
                }
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(model.basicChoicePresentation(for: gameID), "\(label)")
            #expect(prompt.readOnlyReason == .updateRequired, "\(label)")
            #expect(!prompt.isRenderableQuestion, "\(label)")
            if rawFixture.contains("choose-amounts") {
                #expect(
                    await model.submitAmountsAnswer(
                        prompt.identity,
                        amounts: ["00000000-0000-0000-0000-000000000065": 1]
                    ) == .readOnly,
                    "\(label)"
                )
            } else {
                #expect(
                    await model.submitPaymentAmountsAnswer(
                        prompt.identity,
                        amounts: ["00000000-0000-0000-0000-000000000066": 2]
                    ) == .readOnly,
                    "\(label)"
                )
            }
            #expect(await connection.sentData.isEmpty, "\(label)")
        }
    }

    @Test("Amount submissions keep stale, spectator, ownership, and disconnected fences")
    func amountSubmissionsKeepExistingFences() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 207
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        let amounts = ["00000000-0000-0000-0000-000000000065": 1]

        model.liveGameParticipantIdentities[gameID] = .spectator
        #expect(await model.submitAmountsAnswer(identity, amounts: amounts) == .readOnly)
        model.liveGameParticipantIdentities[gameID] = .participant(BoardTestFixtures.playerID("000000000002"))
        #expect(await model.submitAmountsAnswer(identity, amounts: amounts) == .staleQuestion)
        model.liveGameParticipantIdentities[gameID] = try .participant(#require(envelope.playerID))
        model.liveGameConnections[gameID] = nil
        let disconnectedIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitAmountsAnswer(disconnectedIdentity, amounts: amounts) == .readOnly)
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Amount retry uses the current transport and stale identities cannot send")
    func amountRetryAndStaleSendUseExistingStateMachine() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 207
        )
        let first = FakeGameSocketConnection()
        await first.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(model: model, fakes: fakes, envelope: envelope, connection: first)
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        let amounts = ["00000000-0000-0000-0000-000000000065": 1]
        #expect(await model.submitAmountsAnswer(oldIdentity, amounts: amounts) == .retryableFailure)

        await fakes.service.setGetGameGated(true)
        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await first.enqueue(.failure(GameSocketTransportError()))
        await fakes.service.waitUntilGetGamePending(1)
        let waiting = try #require(model.basicChoicePresentation(for: gameID))
        #expect(waiting.identity != oldIdentity)
        #expect(await model.retryBasicChoice(waiting.identity) == .staleQuestion)

        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.canRetry)
        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await model.submitAmountsAnswer(oldIdentity, amounts: amounts) == .staleQuestion)
        let expected = try amountAnswerBytes(amounts: amounts, version: 207)
        #expect(await first.sentData == [expected])
        #expect(await replacement.sentData == [expected])
    }

    private func expectCanonicalFixture(
        _ fixture: String,
        encodes answer: some Encodable
    ) throws {
        let fixtureValue = try ContractJSON.decode(JSONValue.self, from: fixtureData(named: fixture))
        let actual = try ContractJSON.encode(answer)
        let expected = try ContractJSON.encode(fixtureValue)
        #expect(actual == expected)
    }

    private func amountAnswerBytes(amounts: [String: Int], version: Int) throws -> Data {
        try ContractJSON.encode(AmountsAnswer(
            amounts: amounts,
            playerID: BoardTestFixtures.playerID("000000000001"),
            questionVersion: version
        ))
    }

    private func paymentAmountAnswerBytes(amounts: [String: Int], version: Int) throws -> Data {
        try ContractJSON.encode(PaymentAmountsAnswer(
            amounts: amounts,
            playerID: BoardTestFixtures.playerID("000000000001"),
            questionVersion: version
        ))
    }

    private func exchangeAnswerBytes(amount: Int) throws -> Data {
        try ContractJSON.encode(ExchangeAmountsAnswer(
            source: .object(["tag": .string("GameSource")]),
            fromInvestigator: "c01001",
            toInvestigator: "c01002",
            token: "Resource",
            amount: amount
        ))
    }

    private func amountFixtureJSON(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: name))
    }

    private func representativePresentation(named name: String) throws -> JSONValue {
        let value = try amountFixtureJSON("question-presentation-representatives")
        guard case let .object(root) = value,
              case let .array(entries)? = root["presentations"]
        else { throw TestFailure() }
        for entry in entries {
            guard case let .object(object) = entry,
                  object["name"] == .string(name),
                  let presentation = object["presentation"]
            else { continue }
            return presentation
        }
        throw TestFailure()
    }

    private func amountEnvelope(
        rawQuestion: JSONValue,
        presentation: JSONValue,
        questionVersion: Int
    ) throws -> GetGameEnvelope {
        var rootValue = try amountFixtureJSON("get-game")
        guard case var .object(root) = rootValue,
              case var .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"],
              case var .object(presentationObject) = presentation
        else { throw TestFailure() }
        presentationObject["questionVersion"] = .number(.integer(Int64(questionVersion)))
        game["question"] = .object([playerID: rawQuestion])
        game["questionPresentation"] = .object([playerID: .object(presentationObject)])
        game["scenarioSteps"] = .number(.integer(Int64(questionVersion)))
        root["game"] = .object(game)
        rootValue = .object(root)
        return try ContractJSON.decode(GetGameEnvelope.self, from: ContractJSON.encode(rootValue))
    }

    private func exchangeEnvelope(
        fromInitialAmount: Int,
        toInitialAmount: Int
    ) throws -> GetGameEnvelope {
        var presentation = try representativePresentation(named: "chooseExchangeAmounts")
        guard case var .object(presentationObject) = presentation else { throw TestFailure() }
        presentationObject["fromInitialAmount"] = .number(.integer(Int64(fromInitialAmount)))
        presentationObject["toInitialAmount"] = .number(.integer(Int64(toInitialAmount)))
        presentation = .object(presentationObject)
        return try amountEnvelope(
            rawQuestion: .object([
                "tag": .string("ChooseExchangeAmounts"),
                "source": .object(["tag": .string("GameSource")]),
                "investigator1Id": .string("c01001"),
                "investigator1InitialAmount": .number(.integer(Int64(fromInitialAmount))),
                "investigator2Id": .string("c01002"),
                "investigator2InitialAmount": .number(.integer(Int64(toInitialAmount))),
                "token": .string("Resource"),
            ]),
            presentation: presentation,
            questionVersion: 335
        )
    }

    private func chooseAmountsRawQuestion(
        choices: [[String: JSONValue]],
        target: QuestionPresentation.AmountTarget
    ) -> JSONValue {
        .object([
            "tag": .string("ChooseAmounts"),
            "label": .string("$amount"),
            "amountTargetValue": amountTargetJSON(target),
            "amountChoices": .array(choices.map { .object($0) }),
            "target": .object([
                "tag": .string("LocationTarget"),
                "contents": .string("00000000-0000-0000-0000-000000000064"),
            ]),
        ])
    }

    private func chooseAmountsPresentation(
        choices: [[String: JSONValue]],
        target: QuestionPresentation.AmountTarget,
        questionVersion: Int
    ) -> JSONValue {
        .object([
            "protocolVersion": .number(.integer(2)),
            "questionVersion": .number(.integer(Int64(questionVersion))),
            "questionKind": .string("chooseAmounts"),
            "choiceCount": .number(.integer(0)),
            "choices": .array([]),
            "answer": .object(["kind": .string("amounts"), "tag": .string("AmountsAnswer")]),
            "label": .object(["kind": .string("embeddedI18n"), "text": .string("$amount")]),
            "target": amountTargetJSON(target),
            "resolveTarget": .object([
                "tag": .string("LocationTarget"),
                "contents": .string("00000000-0000-0000-0000-000000000064"),
            ]),
            "amountChoices": .array(choices.map { .object($0) }),
        ])
    }

    private func amountChoice(_ id: String, min: Int, max: Int) -> [String: JSONValue] {
        [
            "choiceId": .string(id),
            "label": .string("$clues"),
            "minBound": .number(.integer(Int64(min))),
            "maxBound": .number(.integer(Int64(max))),
        ]
    }

    private func paymentRawQuestion(
        choiceID: String,
        min: Int,
        max: Int,
        target: JSONValue
    ) -> JSONValue {
        .object([
            "tag": .string("ChoosePaymentAmounts"),
            "label": .string("$pay"),
            "paymentAmountTargetValue": target,
            "paymentAmountChoices": .array([
                .object([
                    "choiceId": .string(choiceID),
                    "investigatorId": .string("c01001"),
                    "minBound": .number(.integer(Int64(min))),
                    "maxBound": .number(.integer(Int64(max))),
                    "title": .string("$resources"),
                    "message": .object(["tag": .string("ClearUI")]),
                ]),
            ]),
        ])
    }

    private func amountTargetJSON(_ target: QuestionPresentation.AmountTarget) -> JSONValue {
        switch target {
        case let .min(value):
            .object(["tag": .string("MinAmountTarget"), "contents": .number(.integer(Int64(value)))])
        case let .max(value):
            .object(["tag": .string("MaxAmountTarget"), "contents": .number(.integer(Int64(value)))])
        case let .total(value):
            .object(["tag": .string("TotalAmountTarget"), "contents": .number(.integer(Int64(value)))])
        case let .oneOf(values):
            .object([
                "tag": .string("AmountOneOf"),
                "contents": .array(values.map { .number(.integer(Int64($0))) }),
            ])
        }
    }
}

private func payCostWrapped(_ question: JSONValue) -> JSONValue {
    .object([
        "tag": .string("PayCostQuestion"),
        "cost": .object(["tag": .string("Free")]),
        "question": question,
    ])
}

private func questionLabelWrapped(_ question: JSONValue) -> JSONValue {
    .object([
        "tag": .string("QuestionLabel"),
        "label": .string("Wrapper"),
        "card": .null,
        "question": question,
    ])
}
