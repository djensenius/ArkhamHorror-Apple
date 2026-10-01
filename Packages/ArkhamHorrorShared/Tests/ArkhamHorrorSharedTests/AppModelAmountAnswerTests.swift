// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct IllegalAmountAllocationCase {
    let target: QuestionPresentation.AmountTarget
    let amounts: [String: Int]
    let label: String
}

private struct UnsupportedAmountWrapperCase {
    let label: String
    let rawFixture: String
    let presentationFixture: String
}

private struct AmountPromptPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
}

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
        #expect(
            await model.submitAmountsAnswer(prompt.identity, amounts: amounts) == .alreadyPending
        )
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        let expectedAmountAnswer = try amountAnswerBytes(amounts: amounts, version: 207)
        #expect(await connection.sentData == [expectedAmountAnswer])
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
        let expectedPaymentAnswer = try paymentAmountAnswerBytes(
            amounts: amounts,
            version: 310
        )
        #expect(await connection.sentData == [expectedPaymentAnswer])
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
        #expect(
            await model.submitExchangeAmountsAnswer(prompt.identity, amount: 2)
                == .sentAwaitingSnapshot
        )
        let expectedExchangeAnswer = try exchangeAnswerBytes(amount: 2)
        #expect(await connection.sentData == [expectedExchangeAnswer])

        let (zeroModel, zeroFakes) = makeSignedInModel()
        await zeroModel.flowTask?.value
        makeModern(zeroModel)
        let zeroEnvelope = try exchangeEnvelope(fromInitialAmount: 2, toInitialAmount: 1)
        let zeroConnection = FakeGameSocketConnection()
        await zeroConnection.enqueueSendResult(.success(()))
        let zeroGameID = await startChoiceSession(
            model: zeroModel,
            fakes: zeroFakes,
            envelope: zeroEnvelope,
            connection: zeroConnection
        )
        let zeroPrompt = try #require(zeroModel.basicChoicePresentation(for: zeroGameID))
        #expect(
            await zeroModel.submitExchangeAmountsAnswer(zeroPrompt.identity, amount: 0)
                == .sentAwaitingSnapshot
        )
        let expectedZeroExchangeAnswer = try exchangeAnswerBytes(amount: 0)
        #expect(await zeroConnection.sentData == [expectedZeroExchangeAnswer])
    }

    @Test("Illegal amount allocations are refused without sending")
    // swiftlint:disable:next function_body_length
    func illegalAmountAllocationsAreRefused() async throws {
        let choices: [[String: JSONValue]] = [
            amountChoice("00000000-0000-0000-0000-0000000000a1", min: 0, max: 2),
            amountChoice("00000000-0000-0000-0000-0000000000a2", min: 0, max: 2),
        ]
        let cases: [IllegalAmountAllocationCase] = [
            .init(
                target: .total(2),
                amounts: ["00000000-0000-0000-0000-0000000000a1": 1],
                label: "missing choice"
            ),
            .init(
                target: .total(2),
                amounts: [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 1,
                    "00000000-0000-0000-0000-0000000000ff": 0,
                ],
                label: "extra choice"
            ),
            .init(
                target: .total(2),
                amounts: [
                    "00000000-0000-0000-0000-0000000000a1": -1,
                    "00000000-0000-0000-0000-0000000000a2": 3,
                ],
                label: "bounds"
            ),
            .init(
                target: .min(2),
                amounts: [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 0,
                ],
                label: "min target"
            ),
            .init(
                target: .max(1),
                amounts: [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 1,
                ],
                label: "max target"
            ),
            .init(
                target: .total(2),
                amounts: [
                    "00000000-0000-0000-0000-0000000000a1": 1,
                    "00000000-0000-0000-0000-0000000000a2": 0,
                ],
                label: "total target"
            ),
            .init(
                target: .oneOf([1, 3]),
                amounts: [
                    "00000000-0000-0000-0000-0000000000a1": 2,
                    "00000000-0000-0000-0000-0000000000a2": 0,
                ],
                label: "one-of target"
            ),
        ]
        for testCase in cases {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try amountEnvelope(
                rawQuestion: chooseAmountsRawQuestion(choices: choices, target: testCase.target),
                presentation: chooseAmountsPresentation(
                    choices: choices,
                    target: testCase.target,
                    questionVersion: 411
                ),
                questionVersion: 411
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(
                model.basicChoicePresentation(for: gameID),
                "\(testCase.label)"
            )
            #expect(
                await model.submitAmountsAnswer(prompt.identity, amounts: testCase.amounts)
                    == .unsupportedChoice,
                "\(testCase.label)"
            )
            #expect(await connection.sentData.isEmpty, "\(testCase.label)")
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
        let exchangePrompt = try #require(
            exchangeModel.basicChoicePresentation(for: exchangeGameID)
        )
        #expect(
            await exchangeModel.submitExchangeAmountsAnswer(exchangePrompt.identity, amount: 2)
                == .unsupportedChoice
        )
        #expect(
            await exchangeModel.submitExchangeAmountsAnswer(exchangePrompt.identity, amount: -2)
                == .unsupportedChoice
        )
        #expect(await exchangeConnection.sentData.isEmpty)
    }

    @Test("Allowed amount wrappers render and send exact bytes")
    func allowedAmountWrappersRenderAndSendExactBytes() async throws {
        let amountsCase = try await sendWrappedAmountsAnswer()
        #expect(amountsCase.prompt.isRenderableQuestion)
        #expect(amountsCase.prompt.amountPrompt(in: amountsCase.projection) != nil)
        #expect(
            try await amountsCase.connection.sentData == [
                amountAnswerBytes(
                    amounts: ["00000000-0000-0000-0000-000000000065": 1],
                    version: 617
                ),
            ]
        )

        let paymentCase = try await sendWrappedPaymentAmountsAnswer()
        #expect(paymentCase.prompt.isRenderableQuestion)
        #expect(paymentCase.prompt.amountPrompt(in: paymentCase.projection) != nil)
        #expect(
            try await paymentCase.connection.sentData == [
                paymentAmountAnswerBytes(
                    amounts: ["00000000-0000-0000-0000-000000000066": 2],
                    version: 618
                ),
            ]
        )
    }

    @Test("Legal Min, Max, and OneOf amount allocations are accepted")
    func legalNonTotalAmountTargetsAreAccepted() async throws {
        let cases: [(QuestionPresentation.AmountTarget, [String: Int])] = [
            (.min(2), [
                "00000000-0000-0000-0000-0000000000f1": 1,
                "00000000-0000-0000-0000-0000000000f2": 1,
            ]),
            (.max(2), [
                "00000000-0000-0000-0000-0000000000f1": 2,
                "00000000-0000-0000-0000-0000000000f2": 0,
            ]),
            (.oneOf([1, 3]), [
                "00000000-0000-0000-0000-0000000000f1": 2,
                "00000000-0000-0000-0000-0000000000f2": 1,
            ]),
        ]
        for (index, testCase) in cases.enumerated() {
            let (target, amounts) = testCase
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let choices = [
                amountChoice("00000000-0000-0000-0000-0000000000f1", min: 0, max: 3),
                amountChoice("00000000-0000-0000-0000-0000000000f2", min: 0, max: 3),
            ]
            let version = 630 + index
            let envelope = try amountEnvelope(
                rawQuestion: chooseAmountsRawQuestion(choices: choices, target: target),
                presentation: chooseAmountsPresentation(
                    choices: choices,
                    target: target,
                    questionVersion: version
                ),
                questionVersion: version
            )
            let connection = FakeGameSocketConnection()
            await connection.enqueueSendResult(.success(()))
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(model.basicChoicePresentation(for: gameID))
            let result = await model.submitAmountsAnswer(prompt.identity, amounts: amounts)
            #expect(result == .sentAwaitingSnapshot)
            #expect(try await connection.sentData == [
                amountAnswerBytes(amounts: amounts, version: version),
            ])
        }
    }

    @Test("Unsupported wrappers remain update-required and cannot send amount answers")
    // swiftlint:disable:next function_body_length
    func unsupportedAmountWrappersAreRefused() async throws {
        let wrappers: [UnsupportedAmountWrapperCase] = [
            .init(
                label: "amounts in PayCostQuestion",
                rawFixture: "question-generic-choose-amounts",
                presentationFixture: "question-presentation-generic-choose-amounts"
            ),
            .init(
                label: "payment in QuestionLabel",
                rawFixture: "question-generic-payment-amounts",
                presentationFixture: "question-presentation-generic-payment-amounts"
            ),
        ]
        for wrapper in wrappers {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try semanticEnvelope(
                rawFixture: wrapper.rawFixture,
                presentationFixture: wrapper.presentationFixture,
                questionVersion: 515,
                mutateRawQuestion: { rawQuestion in
                    if wrapper.rawFixture.contains("choose-amounts") {
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
            let prompt = try #require(
                model.basicChoicePresentation(for: gameID),
                "\(wrapper.label)"
            )
            #expect(prompt.readOnlyReason == .updateRequired, "\(wrapper.label)")
            #expect(!prompt.isRenderableQuestion, "\(wrapper.label)")
            if wrapper.rawFixture.contains("choose-amounts") {
                #expect(
                    await model.submitAmountsAnswer(
                        prompt.identity,
                        amounts: ["00000000-0000-0000-0000-000000000065": 1]
                    ) == .readOnly,
                    "\(wrapper.label)"
                )
            } else {
                #expect(
                    await model.submitPaymentAmountsAnswer(
                        prompt.identity,
                        amounts: ["00000000-0000-0000-0000-000000000066": 2]
                    ) == .readOnly,
                    "\(wrapper.label)"
                )
            }
            #expect(await connection.sentData.isEmpty, "\(wrapper.label)")
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
        model.liveGameParticipantIdentities[gameID] = .participant(
            BoardTestFixtures.playerID("000000000002")
        )
        #expect(await model.submitAmountsAnswer(identity, amounts: amounts) == .staleQuestion)
        model.liveGameParticipantIdentities[gameID] = try .participant(#require(envelope.playerID))
        model.liveGameConnections[gameID] = nil
        let disconnectedIdentity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )
        #expect(
            await model.submitAmountsAnswer(disconnectedIdentity, amounts: amounts) == .readOnly
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Exchange prompts without a source expose no enabled submit path")
    @MainActor
    func exchangeWithoutSourceHasNoEnabledSubmit() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        var presentation = try representativePresentation(named: "chooseExchangeAmounts")
        guard case var .object(presentationObject) = presentation else { throw TestFailure() }
        presentationObject["source"] = nil
        presentation = .object(presentationObject)
        let envelope = try amountEnvelope(
            rawQuestion: .object([
                "tag": .string("ChooseExchangeAmounts"),
                "source": .object(["tag": .string("GameSource")]),
                "investigator1Id": .string("c01001"),
                "investigator1InitialAmount": .number(.integer(2)),
                "investigator2Id": .string("c01002"),
                "investigator2InitialAmount": .number(.integer(1)),
                "token": .string("Resource"),
            ]),
            presentation: presentation,
            questionVersion: 616
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        #expect(prompt.exchangePrompt(in: projection) == nil)
        let controller = BoardCommandController(projection: projection, prompt: prompt)
        #expect(!controller.activateExchangeSubmit())
        let result = await model.submitExchangeAmountsAnswer(prompt.identity, amount: 0)
        #expect(result == .readOnly)
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Exchange prompts with negative starting amounts cannot submit")
    func exchangeNegativeInitialAmountsAreRefused() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try exchangeEnvelope(fromInitialAmount: -1, toInitialAmount: 3)
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let exchangePrompt = try #require(prompt.exchangePrompt(in: projection))
        #expect(!exchangePrompt.isLegal(-1))
        #expect(
            await model.submitExchangeAmountsAnswer(prompt.identity, amount: -1)
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Exchange controller adjusts, submits, and handles left/right focus commands")
    @MainActor
    func exchangeControllerPathSubmitsAmount() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try exchangeEnvelope(fromInitialAmount: 2, toInitialAmount: 1)
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onExchangeAmount: { submitted.append($0) }
        )
        #expect(controller.adjustExchangeAmount(delta: 1))
        #expect(controller.exchangeAmount == 1)
        #expect(controller.handle(
            focusID: BoardFocusID.promptExchangeIncrease,
            .command(.focusMove(.right))
        ))
        #expect(controller.exchangeAmount == 2)
        #expect(controller.handle(.command(.focusMove(.left))))
        #expect(controller.exchangeAmount == 1)
        #expect(controller.activateExchangeSubmit())
        #expect(submitted == [1])
    }

    @Test("Amount drafts reset when the prompt changes")
    @MainActor
    func amountDraftResetsWhenPromptChanges() async throws {
        let firstID = "00000000-0000-0000-0000-0000000000aa"
        let secondID = "00000000-0000-0000-0000-0000000000bb"
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let firstEnvelope = try oneChoiceAmountEnvelope(choiceID: firstID, questionVersion: 641)
        let secondEnvelope = try oneChoiceAmountEnvelope(choiceID: secondID, questionVersion: 642)
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: firstEnvelope,
            connection: FakeGameSocketConnection()
        )
        let firstPrompt = try #require(model.basicChoicePresentation(for: gameID))
        let firstProjection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let controller = BoardCommandController(projection: firstProjection, prompt: firstPrompt)
        #expect(controller.adjustAmount(rowID: firstID, delta: 1))
        #expect(controller.amountDraft == [firstID: 1])

        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: secondEnvelope.game)
        )
        let secondPrompt = try #require(model.basicChoicePresentation(for: gameID))
        controller.applyPrompt(secondPrompt)
        #expect(controller.amountDraft == [secondID: 0])
    }

    @Test("Secondary actions reverse amount increment and decrement controls")
    @MainActor
    func secondaryActionsReverseAmountControls() async throws {
        let choiceID = "00000000-0000-0000-0000-0000000000cc"
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try oneChoiceAmountEnvelope(choiceID: choiceID, questionVersion: 643)
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let controller = BoardCommandController(projection: projection, prompt: prompt)
        #expect(controller.handle(
            focusID: BoardFocusID.promptAmountIncrease(0),
            .command(.primaryAction)
        ))
        #expect(controller.amountDraft[choiceID] == 1)
        #expect(controller.handle(.command(.secondaryAction)))
        #expect(controller.amountDraft[choiceID] == 0)
        #expect(controller.handle(
            focusID: BoardFocusID.promptAmountDecrease(0),
            .command(.secondaryAction)
        ))
        #expect(controller.amountDraft[choiceID] == 1)
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
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: first
        )
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

    @Test(
        """
        Amount prompt presentation starts at zero, hides zero rows, gates submit, and supports \
        semantic input
        """
    )
    @MainActor
    func amountPromptPresentationAndInput() async throws {
        let visibleID = "00000000-0000-0000-0000-0000000000b1"
        let hiddenID = "00000000-0000-0000-0000-0000000000b2"
        let choices = [
            amountChoice(visibleID, min: 0, max: 2, label: "Clues"),
            amountChoice(hiddenID, min: 0, max: 0, label: "Hidden"),
        ]
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try amountEnvelope(
            rawQuestion: chooseAmountsRawQuestion(choices: choices, target: .total(2)),
            presentation: chooseAmountsPresentation(
                choices: choices,
                target: .total(2),
                questionVersion: 611
            ),
            questionVersion: 611
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let amountPrompt = try #require(prompt.amountPrompt(in: projection))
        #expect(amountPrompt.initialAmounts == [visibleID: 0, hiddenID: 0])
        #expect(amountPrompt.visibleRows.map(\.id) == [visibleID])
        #expect(amountPrompt.targetHint(in: prompt) == "Choose exactly 2")
        #expect(
            amountPrompt.disabledReason(for: amountPrompt.initialAmounts, in: prompt)
                == "Choose exactly 2"
        )

        var submitted: [String: Int]?
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onAmounts: { submitted = $0 }
        )
        #expect(!controller.activateAmountSubmit())
        #expect(controller.adjustAmount(rowID: visibleID, delta: 1))
        #expect(controller.handle(
            focusID: BoardFocusID.promptAmountIncrease(0),
            .command(.primaryAction)
        ))
        #expect(!controller.adjustAmount(rowID: visibleID, delta: 1))
        let focusAtUpperBound = controller.coordinator.currentFocus
        #expect(controller.handle(.command(.focusMove(.right))))
        #expect(controller.coordinator.currentFocus == focusAtUpperBound)
        #expect(controller.activateAmountSubmit())
        #expect(submitted == [visibleID: 2, hiddenID: 0])
    }

    @Test("Camera zoom commands without a focus ID never alter amount drafts")
    @MainActor
    func zoomWithoutFocusIDLeavesAmountDraftUnchanged() async throws {
        let visibleID = "00000000-0000-0000-0000-0000000000d1"
        let choices = [amountChoice(visibleID, min: 0, max: 3)]
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try amountEnvelope(
            rawQuestion: chooseAmountsRawQuestion(choices: choices, target: .min(0)),
            presentation: chooseAmountsPresentation(
                choices: choices,
                target: .min(0),
                questionVersion: 614
            ),
            questionVersion: 614
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let controller = BoardCommandController(projection: projection, prompt: prompt)

        #expect(controller.handle(
            focusID: BoardFocusID.promptAmountIncrease(0),
            .command(.primaryAction)
        ))
        let draftBeforeZoom = controller.amountDraft
        #expect(controller.handle(.command(.zoomIn)))
        #expect(controller.amountDraft == draftBeforeZoom)
        #expect(controller.zoomScale == 1.25)
        #expect(controller.handle(.command(.adjustFocusedAmount(1))))
        #expect(controller.amountDraft[visibleID] == 2)
    }

    @Test("Amount submit is disabled while visible row labels are unresolved")
    @MainActor
    func unresolvedAmountLabelsDisableSubmitUntilCatalogLoads() async throws {
        let choiceID = "00000000-0000-0000-0000-0000000000e1"
        let choices = [amountChoice(choiceID, min: 0, max: 1)]
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try amountEnvelope(
            rawQuestion: chooseAmountsRawQuestion(choices: choices, target: .total(1)),
            presentation: chooseAmountsPresentation(
                choices: choices,
                target: .total(1),
                questionVersion: 615
            ),
            questionVersion: 615
        )
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let promptWithoutCatalog = try #require(prompt.amountPrompt(in: projection))
        let legalAmounts = [choiceID: 1]
        #expect(!promptWithoutCatalog.isLegal(legalAmounts))
        #expect(promptWithoutCatalog.disabledReason(for: legalAmounts, in: prompt) != nil)

        let documents = try amountLabelCatalogDocuments()
        let (catalogModel, catalogFakes) = makeAmountCatalogModel(documents: documents)
        await catalogModel.flowTask?.value
        await catalogModel.localeCatalogTask?.value
        let catalogGameID = await startChoiceSession(
            model: catalogModel,
            fakes: catalogFakes,
            envelope: envelope,
            connection: FakeGameSocketConnection()
        )
        let catalogPrompt = try #require(catalogModel.basicChoicePresentation(for: catalogGameID))
        let catalogProjection = try #require(
            catalogModel.liveGameStates[catalogGameID]?.lastKnownProjection
        )
        let promptWithCatalog = try #require(catalogPrompt.amountPrompt(in: catalogProjection))
        #expect(promptWithCatalog.visibleRows.first?.title == "Localized clue")
        #expect(promptWithCatalog.isLegal(legalAmounts))
        #expect(promptWithCatalog.disabledReason(for: legalAmounts, in: catalogPrompt) == nil)
    }

    @Test("Payment and exchange prompts expose target hints, investigator names, and bounds")
    @MainActor
    // swiftlint:disable:next function_body_length
    func paymentAndExchangePromptPresentation() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let paymentEnvelope = try amountEnvelope(
            rawQuestion: paymentRawQuestion(
                choiceID: "00000000-0000-0000-0000-0000000000c1",
                min: 0,
                max: 3,
                target: .null
            ),
            presentation: representativePresentation(named: "choosePaymentAmounts-null-target"),
            questionVersion: 612
        )
        let paymentGameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: paymentEnvelope,
            connection: FakeGameSocketConnection()
        )
        let paymentPrompt = try #require(model.basicChoicePresentation(for: paymentGameID))
        let paymentProjection = try #require(
            model.liveGameStates[paymentGameID]?.lastKnownProjection
        )
        let payment = try #require(paymentPrompt.amountPrompt(in: paymentProjection))
        #expect(payment.kind == .payment)
        #expect(payment.targetHint(in: paymentPrompt) == "Choose any amount")
        #expect(payment.isLegal(payment.initialAmounts))

        let (exchangeModel, exchangeFakes) = makeSignedInModel()
        await exchangeModel.flowTask?.value
        makeModern(exchangeModel)
        exchangeModel.cardCatalog = try CardCatalogSnapshot(namesByCode: [
            CardCode("c01002"): CardName(title: "Daisy Walker", subtitle: nil),
        ])
        let exchangeEnvelope = try exchangeEnvelope(fromInitialAmount: 2, toInitialAmount: 1)
        let exchangeGameID = await startChoiceSession(
            model: exchangeModel,
            fakes: exchangeFakes,
            envelope: exchangeEnvelope,
            connection: FakeGameSocketConnection()
        )
        let exchangePromptPresentation = try #require(
            exchangeModel.basicChoicePresentation(for: exchangeGameID)
        )
        let exchangeProjection = try #require(
            exchangeModel.liveGameStates[exchangeGameID]?.lastKnownProjection
        )
        let exchange = try #require(
            exchangePromptPresentation.exchangePrompt(in: exchangeProjection)
        )
        #expect(exchange.lowerBound == -1)
        #expect(exchange.upperBound == 2)
        #expect(exchange.isLegal(0))
        #expect(!exchange.isLegal(3))
        #expect(exchange.fromDisplayName != exchange.fromInvestigator)
        #expect(exchange.toDisplayName != exchange.toInvestigator)
    }

    @Test("Amount controller drives a legal allocation through AppModel and sends exact bytes")
    @MainActor
    func amountControllerSubmitsExactBytesThroughAppModel() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 613
        )
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let amountPrompt = try #require(prompt.amountPrompt(in: projection))
        let rowID = try #require(amountPrompt.visibleRows.first?.id)
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onAmounts: { amounts in
                Task { await model.submitAmountsAnswer(prompt.identity, amounts: amounts) }
            }
        )

        #expect(controller.adjustAmount(rowID: rowID, delta: 1))
        #expect(controller.activateAmountSubmit())
        await connection.waitUntilSendPending(1)
        await connection.resumeOldestSend(with: .success(()))
        let expected = try amountAnswerBytes(amounts: [rowID: 1], version: 613)
        #expect(await connection.sentData == [expected])
    }

    private func oneChoiceAmountEnvelope(
        choiceID: String,
        questionVersion: Int
    ) throws -> GetGameEnvelope {
        let choices = [amountChoice(choiceID, min: 0, max: 2)]
        return try amountEnvelope(
            rawQuestion: chooseAmountsRawQuestion(choices: choices, target: .min(0)),
            presentation: chooseAmountsPresentation(
                choices: choices,
                target: .min(0),
                questionVersion: questionVersion
            ),
            questionVersion: questionVersion
        )
    }

    private func sendWrappedAmountsAnswer() async throws -> (
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        connection: FakeGameSocketConnection
    ) {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 617,
            mutateRawQuestion: { rawQuestion in
                rawQuestion = questionLabelWrapped(rawQuestion)
            }
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(
            await model.submitAmountsAnswer(
                prompt.identity,
                amounts: ["00000000-0000-0000-0000-000000000065": 1]
            ) == .sentAwaitingSnapshot
        )
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        return (prompt, projection, connection)
    }

    private func sendWrappedPaymentAmountsAnswer() async throws -> (
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        connection: FakeGameSocketConnection
    ) {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-payment-amounts",
            presentationFixture: "question-presentation-generic-payment-amounts",
            questionVersion: 618,
            mutateRawQuestion: { rawQuestion in
                rawQuestion = payCostWrapped(rawQuestion)
            }
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(
            await model.submitPaymentAmountsAnswer(
                prompt.identity,
                amounts: ["00000000-0000-0000-0000-000000000066": 2]
            ) == .sentAwaitingSnapshot
        )
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        return (prompt, projection, connection)
    }

    private func amountLabelCatalogDocuments() throws -> SyntheticLocaleCatalogDocuments {
        try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["clues"],
            chunkEntries: """
            {"clues":{"form":"message","nodes":[{"type":"text","value":"Localized clue"}],\
            "variables":[]}}
            """
        )
    }

    private func makeAmountCatalogModel(
        documents: SyntheticLocaleCatalogDocuments
    ) -> (model: AppModel, fakes: Fakes) {
        let tokenStore = FakeTokenStore(tokens: [documents.profile.id: "catalog-token"])
        let service = ScriptedGameLifecycleService()
        let socketFactory = FakeGameSocketFactory()
        let clock = FakeLiveGameClock()
        let random = FakeLiveGameRandomSource(values: [0])
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, documents.profile],
                selectedID: documents.profile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: documents.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service,
            liveGameSocketFactory: socketFactory,
            liveGameClock: clock,
            liveGameRandomSource: random,
            localeCatalogLoader: documents.loader(),
            preferredLanguagesProvider: AmountPromptPreferredLanguages(preferredLanguages: ["en"])
        )
        return (
            model,
            Fakes(
                tokenStore: tokenStore,
                service: service,
                socketFactory: socketFactory,
                clock: clock,
                random: random
            )
        )
    }

    private func expectCanonicalFixture(
        _ fixture: String,
        encodes answer: some Encodable
    ) throws {
        let fixtureValue = try ContractJSON.decode(
            JSONValue.self,
            from: fixtureData(named: fixture)
        )
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

    private func amountChoice(
        _ id: String, min: Int, max: Int, label: String = "$clues"
    ) -> [String: JSONValue] {
        [
            "choiceId": .string(id),
            "label": .string(label),
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
            .object([
                "tag": .string("MinAmountTarget"),
                "contents": .number(.integer(Int64(value))),
            ])
        case let .max(value):
            .object([
                "tag": .string("MaxAmountTarget"),
                "contents": .number(.integer(Int64(value))),
            ])
        case let .total(value):
            .object([
                "tag": .string("TotalAmountTarget"),
                "contents": .number(.integer(Int64(value))),
            ])
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
