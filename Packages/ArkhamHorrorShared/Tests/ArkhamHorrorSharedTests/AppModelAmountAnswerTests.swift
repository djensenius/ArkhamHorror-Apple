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

private struct PresentationMutationCase {
    let label: String
    let mutate: (inout [String: JSONValue]) throws -> Void
}

private struct JSONMutationCase {
    let label: String
    let mutate: (inout JSONValue) throws -> Void
}

private struct AmountPromptPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
}

private struct WrappedAmountSendCase {
    let prompt: BasicChoicePromptPresentation
    let projection: BoardProjection
    let connection: FakeGameSocketConnection
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
            questionVersion: 207,
            mutateRawQuestion: localizeFirstRawAmountChoiceLabel,
            mutatePresentation: localizeFirstAmountChoiceLabel
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
        var presentation = try representativePresentation(named: "choosePaymentAmounts-null-target")
        try localizeFirstPaymentChoiceTitle(in: &presentation)
        let envelope = try amountEnvelope(
            rawQuestion: paymentRawQuestion(
                choiceID: "00000000-0000-0000-0000-00000000004d",
                min: 0,
                max: 3,
                target: .null,
                title: "Resources"
            ),
            presentation: presentation,
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
            amountChoice("00000000-0000-0000-0000-0000000000a1", min: 0, max: 2, label: "A"),
            amountChoice("00000000-0000-0000-0000-0000000000a2", min: 0, max: 2, label: "B"),
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

    @Test("Overflowing amount totals are refused without trapping or sending")
    @MainActor
    func overflowingAmountTotalsAreRefused() async throws {
        let firstID = "00000000-0000-0000-0000-0000000000b3"
        let secondID = "00000000-0000-0000-0000-0000000000b4"
        let choices = [
            amountChoice(firstID, min: 0, max: Int.max, label: "A"),
            amountChoice(secondID, min: 0, max: Int.max, label: "B"),
        ]
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try amountEnvelope(
            rawQuestion: chooseAmountsRawQuestion(choices: choices, target: .min(0)),
            presentation: chooseAmountsPresentation(
                choices: choices,
                target: .min(0),
                questionVersion: 644
            ),
            questionVersion: 644
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let amountPrompt = try #require(prompt.amountPrompt(in: projection))
        let amounts = [firstID: Int.max, secondID: 1]

        #expect(amountPrompt.total(for: amounts) == nil)
        #expect(!amountPrompt.isLegal(amounts))
        #expect(amountPrompt.disabledReason(for: amounts, in: prompt) != nil)
        #expect(
            await model.submitAmountsAnswer(prompt.identity, amounts: amounts) == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Exchange bound arithmetic refuses Int.min without trapping or sending")
    @MainActor
    func exchangeIntMinBoundIsRefused() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try exchangeEnvelope(fromInitialAmount: 1, toInitialAmount: Int.min)
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let exchangePrompt = try #require(prompt.exchangePrompt(in: projection))

        #expect(exchangePrompt.bounds == nil)
        #expect(!exchangePrompt.isLegal(0))
        #expect(
            await model.submitExchangeAmountsAnswer(prompt.identity, amount: 0)
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
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

    @Test("Unmodified raw amount fixtures remain renderable")
    @MainActor
    func unmodifiedRawAmountFixturesRemainRenderable() async throws {
        let amountCase = try await renderPrompt(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 650
        )
        #expect(amountCase.prompt.readOnlyReason == nil)
        #expect(amountCase.prompt.isRenderableQuestion)
        #expect(amountCase.prompt.amountPrompt(in: amountCase.projection) != nil)

        let paymentCase = try await renderPrompt(
            rawFixture: "question-generic-payment-amounts",
            presentationFixture: "question-presentation-generic-payment-amounts",
            questionVersion: 651
        )
        #expect(paymentCase.prompt.readOnlyReason == nil)
        #expect(paymentCase.prompt.isRenderableQuestion)
        #expect(paymentCase.prompt.amountPrompt(in: paymentCase.projection) != nil)
    }

    @Test("Amount and payment presentation drift is update-required and cannot send")
    @MainActor
    // swiftlint:disable:next function_body_length
    func amountAndPaymentPresentationDriftIsUpdateRequired() async throws {
        let amountCases = amountBindingMutationCases()
        for testCase in amountCases {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try semanticEnvelope(
                rawFixture: "question-generic-choose-amounts",
                presentationFixture: "question-presentation-generic-choose-amounts",
                questionVersion: 652,
                mutatePresentation: testCase.mutate
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(
                model.basicChoicePresentation(for: gameID),
                Comment(rawValue: testCase.label)
            )
            #expect(
                prompt.readOnlyReason == BasicChoiceReadOnlyReason.updateRequired,
                Comment(rawValue: testCase.label)
            )
            #expect(!prompt.isRenderableQuestion, Comment(rawValue: testCase.label))
            #expect(
                await model.submitAmountsAnswer(
                    prompt.identity,
                    amounts: ["00000000-0000-0000-0000-000000000065": 1]
                ) == .readOnly,
                Comment(rawValue: testCase.label)
            )
            #expect(await connection.sentData.isEmpty, Comment(rawValue: testCase.label))
        }

        let paymentCases = paymentBindingMutationCases()
        for testCase in paymentCases {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try semanticEnvelope(
                rawFixture: "question-generic-payment-amounts",
                presentationFixture: "question-presentation-generic-payment-amounts",
                questionVersion: 653,
                mutatePresentation: testCase.mutate
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(
                model.basicChoicePresentation(for: gameID),
                Comment(rawValue: testCase.label)
            )
            #expect(
                prompt.readOnlyReason == BasicChoiceReadOnlyReason.updateRequired,
                Comment(rawValue: testCase.label)
            )
            #expect(!prompt.isRenderableQuestion, Comment(rawValue: testCase.label))
            #expect(
                await model.submitPaymentAmountsAnswer(
                    prompt.identity,
                    amounts: ["00000000-0000-0000-0000-000000000066": 2]
                ) == .readOnly,
                Comment(rawValue: testCase.label)
            )
            #expect(await connection.sentData.isEmpty, Comment(rawValue: testCase.label))
        }
    }

    @Test("Exchange presentation drift is update-required and cannot send")
    @MainActor
    func exchangePresentationDriftIsUpdateRequired() async throws {
        for testCase in exchangeBindingMutationCases() {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            var presentation = try representativePresentation(named: "chooseExchangeAmounts")
            try testCase.mutate(&presentation)
            let envelope = try amountEnvelope(
                rawQuestion: exchangeRawQuestion(fromInitialAmount: 2, toInitialAmount: 1),
                presentation: presentation,
                questionVersion: 654
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(
                model.basicChoicePresentation(for: gameID),
                Comment(rawValue: testCase.label)
            )
            #expect(
                prompt.readOnlyReason == BasicChoiceReadOnlyReason.updateRequired,
                Comment(rawValue: testCase.label)
            )
            #expect(!prompt.isRenderableQuestion, Comment(rawValue: testCase.label))
            #expect(
                await model.submitExchangeAmountsAnswer(prompt.identity, amount: 0)
                    == .readOnly,
                Comment(rawValue: testCase.label)
            )
            #expect(await connection.sentData.isEmpty, Comment(rawValue: testCase.label))
        }
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
            let documents = try amountLabelCatalogDocuments()
            let (model, fakes) = makeAmountCatalogModel(documents: documents)
            await model.flowTask?.value
            await model.localeCatalogTask?.value
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

    @Test("Model refuses amount submissions while visible row labels are unresolved")
    func unresolvedAmountLabelsAreRefusedByModel() async throws {
        let choiceID = "00000000-0000-0000-0000-0000000000f3"
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try oneChoiceAmountEnvelope(choiceID: choiceID, questionVersion: 619)
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let result = await model.submitAmountsAnswer(prompt.identity, amounts: [choiceID: 1])
        #expect(result == .unsupportedChoice)
        #expect(await connection.sentData.isEmpty)

        let (paymentModel, paymentFakes) = makeSignedInModel()
        await paymentModel.flowTask?.value
        makeModern(paymentModel)
        let paymentEnvelope = try amountEnvelope(
            rawQuestion: paymentRawQuestion(
                choiceID: "00000000-0000-0000-0000-00000000004d",
                min: 0,
                max: 3,
                target: .null
            ),
            presentation: representativePresentation(named: "choosePaymentAmounts-null-target"),
            questionVersion: 620
        )
        let paymentConnection = FakeGameSocketConnection()
        let paymentGameID = await startChoiceSession(
            model: paymentModel,
            fakes: paymentFakes,
            envelope: paymentEnvelope,
            connection: paymentConnection
        )
        let paymentPrompt = try #require(
            paymentModel.basicChoicePresentation(for: paymentGameID)
        )
        let paymentResult = await paymentModel.submitPaymentAmountsAnswer(
            paymentPrompt.identity,
            amounts: ["00000000-0000-0000-0000-00000000004d": 0]
        )
        #expect(paymentResult == .unsupportedChoice)
        #expect(await paymentConnection.sentData.isEmpty)
    }

    @Test("A fallback title does not make an unavailable amount label submittable")
    @MainActor
    func amountLabelWithTitleAndUnavailableReasonIsRefused() async throws {
        let choiceID = "00000000-0000-0000-0000-0000000000e2"
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try oneChoiceAmountEnvelope(choiceID: choiceID, questionVersion: 622)
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let amountPrompt = try #require(prompt.amountPrompt(in: projection))
        let row = try #require(amountPrompt.visibleRows.first)
        let amounts = [choiceID: 1]

        #expect(row.title == "Choice 1")
        #expect(row.labelUnavailableReason != nil)
        #expect(!amountPrompt.isLegal(amounts))
        #expect(
            amountPrompt.disabledReason(for: amounts, in: prompt)
                == "The text for Choice 1 is not currently available."
        )
        #expect(
            await model.submitAmountsAnswer(prompt.identity, amounts: amounts) == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Amount retry re-checks unresolved row labels before sending again")
    func amountRetryRefusesWhenCatalogDisappears() async throws {
        let choiceID = "00000000-0000-0000-0000-0000000000f4"
        let documents = try amountLabelCatalogDocuments()
        let (model, fakes) = makeAmountCatalogModel(documents: documents)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try oneChoiceAmountEnvelope(choiceID: choiceID, questionVersion: 621)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let amounts = [choiceID: 1]
        #expect(
            await model.submitAmountsAnswer(prompt.identity, amounts: amounts) == .retryableFailure
        )
        #expect(try await connection.sentData == [
            amountAnswerBytes(amounts: amounts, version: 621),
        ])

        model.invalidateLocaleCatalog()
        let retryPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(retryPrompt.canRetry)
        await connection.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(retryPrompt.identity) == .unsupportedChoice)
        #expect(try await connection.sentData == [
            amountAnswerBytes(amounts: amounts, version: 621),
        ])
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
            questionVersion: 207,
            mutateRawQuestion: localizeFirstRawAmountChoiceLabel,
            mutatePresentation: localizeFirstAmountChoiceLabel
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
        try await assertExchangeNegativeInitialAmountRefused(
            fromInitialAmount: -1,
            toInitialAmount: 3,
            submittedAmount: -1
        )
        try await assertExchangeNegativeInitialAmountRefused(
            fromInitialAmount: 3,
            toInitialAmount: -1,
            submittedAmount: 1
        )
    }

    private func assertExchangeNegativeInitialAmountRefused(
        fromInitialAmount: Int,
        toInitialAmount: Int,
        submittedAmount: Int
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try exchangeEnvelope(
            fromInitialAmount: fromInitialAmount,
            toInitialAmount: toInitialAmount
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let exchangePrompt = try #require(prompt.exchangePrompt(in: projection))
        #expect(!exchangePrompt.isLegal(submittedAmount))
        #expect(
            await model.submitExchangeAmountsAnswer(prompt.identity, amount: submittedAmount)
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
        #expect(controller.coordinator.graph.node(for: BoardFocusID.promptExchangeIncrease) == nil)
        #expect(!controller.handle(
            focusID: BoardFocusID.promptExchangeIncrease,
            .command(.primaryAction)
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
            questionVersion: 207,
            mutateRawQuestion: localizeFirstRawAmountChoiceLabel,
            mutatePresentation: localizeFirstAmountChoiceLabel
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
    // swiftlint:disable:next function_body_length
    func amountPromptPresentationAndInput() async throws {
        let visibleID = "00000000-0000-0000-0000-0000000000b1"
        let hiddenID = "00000000-0000-0000-0000-0000000000b2"
        let choices = [
            amountChoice(visibleID, min: 0, max: 2, label: "Clues"),
            amountChoice(hiddenID, min: 0, max: 0, label: "$hidden"),
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
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptAmountIncrease(0))
        #expect(!controller.activateAmountSubmit())
        #expect(controller.adjustAmount(rowID: visibleID, delta: 1))
        #expect(controller.handle(
            focusID: BoardFocusID.promptAmountIncrease(0),
            .command(.primaryAction)
        ))
        #expect(
            controller.coordinator.graph.node(for: BoardFocusID.promptAmountIncrease(0)) == nil
        )
        #expect(controller.coordinator.graph.node(for: BoardFocusID.promptAmountSubmit) != nil)
        #expect(!controller.handle(
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
        #expect(controller.handle(.command(.adjustFocusedAmount(1))))
        #expect(controller.amountDraft[visibleID] == 3)
        let zoomAtAmountBound = controller.zoomScale
        #expect(controller.handle(.command(.adjustFocusedAmount(1))))
        #expect(controller.amountDraft[visibleID] == 3)
        #expect(controller.zoomScale == zoomAtAmountBound)
    }

    @Test("Amount and exchange chrome strings format with and without a catalog locale")
    func amountChromeStringsFormatWithoutRawPlaceholders() {
        let englishPrompt = amountChromePrompt(locale: nil)
        let english = amountChromeStrings(in: englishPrompt)
        #expect(english == [
            "Total: 2",
            "Choice 4",
            "Choose at least 1",
            "Choose at most 3",
            "Choose exactly 2",
            "Choose one of 1, 3",
            "The text for $clues is not currently available.",
            "Allowed 0–3",
            "Decrease Clues",
            "Increase Clues",
            "2, allowed 0 to 3",
            "Exchange resource",
            "Move one resource back to Roland",
            "Move one resource to Daisy",
            "2 to Daisy",
            "1 to Roland",
            "Roland has 3. Daisy has 1.",
        ])
        #expect(!english.contains { $0.contains("%") })

        let germanPrompt = amountChromePrompt(locale: "de")
        let german = amountChromeStrings(in: germanPrompt)
        #expect(german == [
            "Gesamt: 2",
            "Auswahl 4",
            "Mindestens 1 wählen",
            "Höchstens 3 wählen",
            "Genau 2 wählen",
            "Einen Wert aus 1, 3 wählen",
            "Der Text für $clues ist derzeit nicht verfügbar.",
            "Erlaubt 0–3",
            "Clues verringern",
            "Clues erhöhen",
            "2, erlaubt 0 bis 3",
            "Ressource tauschen",
            "1 × Ressource zurück zu Roland bewegen",
            "1 × Ressource zu Daisy bewegen",
            "2 zu Daisy",
            "1 zu Roland",
            "Roland hat 3. Daisy hat 1.",
        ])
        #expect(!german.contains { $0.contains("%") })
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
        var paymentPresentation = try representativePresentation(
            named: "choosePaymentAmounts-null-target"
        )
        try localizeFirstPaymentChoiceTitle(in: &paymentPresentation)
        let paymentEnvelope = try amountEnvelope(
            rawQuestion: paymentRawQuestion(
                choiceID: "00000000-0000-0000-0000-0000000000c1",
                min: 0,
                max: 3,
                target: .null,
                title: "Resources"
            ),
            presentation: paymentPresentation,
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
        let envelope = try oneChoiceAmountEnvelope(
            choiceID: "00000000-0000-0000-0000-000000000065",
            questionVersion: 613,
            label: "Clues"
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

    private func amountChromePrompt(locale: String?) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 1,
                rawQuestion: .object(["tag": .string("ChooseAmounts")]),
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: "ChooseAmounts"),
            semanticLocaleIdentifier: locale,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    // swiftlint:disable:next function_body_length
    private func amountChromeStrings(in prompt: BasicChoicePromptPresentation) -> [String] {
        let resource = prompt.semanticLocalized("amountPrompt.token.resource", value: "resource")
        let rowTitle = "Clues"
        let unresolvedLabel = "$clues"
        let allowed = "1, 3"
        let roland = "Roland"
        let daisy = "Daisy"
        return [
            prompt.semanticLocalized(
                "amountPrompt.total",
                value: "Total: \(2)",
                arguments: [Int64(2)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.row.fallback",
                value: "Choice \(4)",
                arguments: [Int64(4)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.target.min",
                value: "Choose at least \(1)",
                arguments: [Int64(1)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.target.max",
                value: "Choose at most \(3)",
                arguments: [Int64(3)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.target.total",
                value: "Choose exactly \(2)",
                arguments: [Int64(2)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.target.oneOf",
                value: "Choose one of \(allowed)",
                arguments: [allowed]
            ),
            prompt.semanticLocalized(
                "amountPrompt.disabled.labels",
                value: "The text for \(unresolvedLabel) is not currently available.",
                arguments: [unresolvedLabel]
            ),
            prompt.semanticLocalized(
                "amountPrompt.row.bounds",
                value: "Allowed \(0)–\(3)",
                arguments: [Int64(0), Int64(3)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.decrease.accessibility",
                value: "Decrease \(rowTitle)",
                arguments: [rowTitle]
            ),
            prompt.semanticLocalized(
                "amountPrompt.increase.accessibility",
                value: "Increase \(rowTitle)",
                arguments: [rowTitle]
            ),
            prompt.semanticLocalized(
                "amountPrompt.row.value",
                value: "\(2), allowed \(0) to \(3)",
                arguments: [Int64(2), Int64(0), Int64(3)]
            ),
            prompt.semanticLocalized(
                "amountPrompt.exchange.legend",
                value: "Exchange \(resource)",
                arguments: [resource]
            ),
            prompt.semanticLocalized(
                "amountPrompt.exchange.decrease.accessibility",
                value: "Move one \(resource) back to \(roland)",
                arguments: [resource, roland]
            ),
            prompt.semanticLocalized(
                "amountPrompt.exchange.increase.accessibility",
                value: "Move one \(resource) to \(daisy)",
                arguments: [resource, daisy]
            ),
            prompt.semanticLocalized(
                "amountPrompt.exchange.forward",
                value: "\(2) to \(daisy)",
                arguments: [Int64(2), daisy]
            ),
            prompt.semanticLocalized(
                "amountPrompt.exchange.backward",
                value: "\(1) to \(roland)",
                arguments: [Int64(1), roland]
            ),
            prompt.semanticLocalized(
                "amountPrompt.exchange.accessibility",
                value: "\(roland) has \(3). \(daisy) has \(1).",
                arguments: [roland, Int64(3), daisy, Int64(1)]
            ),
        ]
    }

    private func oneChoiceAmountEnvelope(
        choiceID: String,
        questionVersion: Int,
        label: String = "$clues"
    ) throws -> GetGameEnvelope {
        let choices = [amountChoice(choiceID, min: 0, max: 2, label: label)]
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

    private func renderPrompt(
        rawFixture: String,
        presentationFixture: String,
        questionVersion: Int
    ) async throws -> WrappedAmountSendCase {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: rawFixture,
            presentationFixture: presentationFixture,
            questionVersion: questionVersion
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        return WrappedAmountSendCase(
            prompt: prompt,
            projection: projection,
            connection: connection
        )
    }

    private func amountBindingMutationCases() -> [PresentationMutationCase] {
        [
            PresentationMutationCase(label: "amount choice id") { presentation in
                try mutateFirstChoice(in: &presentation, key: "amountChoices") { choice in
                    choice["choiceId"] = .string("00000000-0000-0000-0000-0000000000ff")
                }
            },
            PresentationMutationCase(label: "amount lower bound") { presentation in
                try mutateFirstChoice(in: &presentation, key: "amountChoices") { choice in
                    choice["minBound"] = .number(.integer(1))
                }
            },
            PresentationMutationCase(label: "amount upper bound") { presentation in
                try mutateFirstChoice(in: &presentation, key: "amountChoices") { choice in
                    choice["maxBound"] = .number(.integer(4))
                }
            },
            PresentationMutationCase(label: "amount label") { presentation in
                try mutateFirstChoice(in: &presentation, key: "amountChoices") { choice in
                    choice["label"] = .string("Clues")
                }
            },
            PresentationMutationCase(label: "amount target") { presentation in
                presentation["target"] = .object([
                    "tag": .string("MinAmountTarget"),
                    "contents": .number(.integer(1)),
                ])
            },
        ]
    }

    private func paymentBindingMutationCases() -> [PresentationMutationCase] {
        [
            PresentationMutationCase(label: "payment choice id") { presentation in
                try mutateFirstChoice(in: &presentation, key: "paymentChoices") { choice in
                    choice["choiceId"] = .string("00000000-0000-0000-0000-0000000000ff")
                }
            },
            PresentationMutationCase(label: "payment investigator") { presentation in
                try mutateFirstChoice(in: &presentation, key: "paymentChoices") { choice in
                    choice["investigatorId"] = .string("c02002")
                }
            },
            PresentationMutationCase(label: "payment lower bound") { presentation in
                try mutateFirstChoice(in: &presentation, key: "paymentChoices") { choice in
                    choice["min"] = .number(.integer(1))
                }
            },
            PresentationMutationCase(label: "payment upper bound") { presentation in
                try mutateFirstChoice(in: &presentation, key: "paymentChoices") { choice in
                    choice["max"] = .number(.integer(3))
                }
            },
            PresentationMutationCase(label: "payment title") { presentation in
                try mutateFirstChoice(in: &presentation, key: "paymentChoices") { choice in
                    choice["title"] = .object([
                        "kind": .string("embeddedI18n"),
                        "text": .string("Resources"),
                    ])
                }
            },
            PresentationMutationCase(label: "payment target") { presentation in
                presentation["target"] = .object([
                    "tag": .string("TotalAmountTarget"),
                    "contents": .number(.integer(3)),
                ])
            },
        ]
    }

    private func exchangeBindingMutationCases() -> [JSONMutationCase] {
        [
            JSONMutationCase(label: "exchange source") { presentation in
                try mutateObject(&presentation) { object in
                    object["source"] = .object(["tag": .string("ScenarioSource")])
                }
            },
            JSONMutationCase(label: "exchange from investigator") { presentation in
                try mutateObject(&presentation) { object in
                    object["fromInvestigator"] = .string("c02002")
                }
            },
            JSONMutationCase(label: "exchange from amount") { presentation in
                try mutateObject(&presentation) { object in
                    object["fromInitialAmount"] = .number(.integer(3))
                }
            },
            JSONMutationCase(label: "exchange to investigator") { presentation in
                try mutateObject(&presentation) { object in
                    object["toInvestigator"] = .string("c02003")
                }
            },
            JSONMutationCase(label: "exchange to amount") { presentation in
                try mutateObject(&presentation) { object in
                    object["toInitialAmount"] = .number(.integer(2))
                }
            },
            JSONMutationCase(label: "exchange token") { presentation in
                try mutateObject(&presentation) { object in
                    object["token"] = .string("Clue")
                }
            },
        ]
    }

    private func mutateFirstChoice(
        in presentation: inout [String: JSONValue],
        key: String,
        mutate: (inout [String: JSONValue]) throws -> Void
    ) throws {
        guard case var .array(choices)? = presentation[key],
              case var .object(choice)? = choices.first
        else { throw TestFailure() }
        try mutate(&choice)
        choices[0] = .object(choice)
        presentation[key] = .array(choices)
    }

    private func mutateObject(
        _ value: inout JSONValue,
        mutate: (inout [String: JSONValue]) throws -> Void
    ) throws {
        guard case var .object(object) = value else { throw TestFailure() }
        try mutate(&object)
        value = .object(object)
    }

    private func sendWrappedAmountsAnswer() async throws -> WrappedAmountSendCase {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-amounts",
            presentationFixture: "question-presentation-generic-choose-amounts",
            questionVersion: 617,
            mutateRawQuestion: { rawQuestion in
                try localizeFirstRawAmountChoiceLabel(in: &rawQuestion)
                rawQuestion = questionLabelWrapped(rawQuestion)
            },
            mutatePresentation: localizeFirstAmountChoiceLabel
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
        return WrappedAmountSendCase(
            prompt: prompt,
            projection: projection,
            connection: connection
        )
    }

    private func sendWrappedPaymentAmountsAnswer() async throws -> WrappedAmountSendCase {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-payment-amounts",
            presentationFixture: "question-presentation-generic-payment-amounts",
            questionVersion: 618,
            mutateRawQuestion: { rawQuestion in
                try localizeFirstRawPaymentChoiceTitle(in: &rawQuestion)
                rawQuestion = payCostWrapped(rawQuestion)
            },
            mutatePresentation: localizeFirstPaymentChoiceTitle
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
        return WrappedAmountSendCase(
            prompt: prompt,
            projection: projection,
            connection: connection
        )
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

    private func localizeFirstAmountChoiceLabel(in presentation: inout [String: JSONValue]) throws {
        guard case var .array(amountChoices)? = presentation["amountChoices"],
              case var .object(choice)? = amountChoices.first
        else { throw TestFailure() }
        choice["label"] = .string("Clues")
        amountChoices[0] = .object(choice)
        presentation["amountChoices"] = .array(amountChoices)
    }

    private func localizeFirstRawAmountChoiceLabel(in rawQuestion: inout JSONValue) throws {
        guard case var .object(root) = rawQuestion,
              case var .array(amountChoices)? = root["amountChoices"],
              case var .object(choice)? = amountChoices.first
        else { throw TestFailure() }
        choice["label"] = .string("Clues")
        amountChoices[0] = .object(choice)
        root["amountChoices"] = .array(amountChoices)
        rawQuestion = .object(root)
    }

    private func localizeFirstPaymentChoiceTitle(
        in presentation: inout [String: JSONValue]
    ) throws {
        var presentationValue = JSONValue.object(presentation)
        try localizeFirstPaymentChoiceTitle(in: &presentationValue)
        guard case let .object(updatedPresentation) = presentationValue else { throw TestFailure() }
        presentation = updatedPresentation
    }

    private func localizeFirstPaymentChoiceTitle(in presentation: inout JSONValue) throws {
        guard case var .object(root) = presentation,
              case var .array(paymentChoices)? = root["paymentChoices"],
              case var .object(choice)? = paymentChoices.first,
              case var .object(title)? = choice["title"]
        else { throw TestFailure() }
        title["text"] = .string("Resources")
        choice["title"] = .object(title)
        paymentChoices[0] = .object(choice)
        root["paymentChoices"] = .array(paymentChoices)
        presentation = .object(root)
    }

    private func localizeFirstRawPaymentChoiceTitle(in rawQuestion: inout JSONValue) throws {
        guard case var .object(root) = rawQuestion,
              case var .array(paymentChoices)? = root["paymentAmountChoices"],
              case var .object(choice)? = paymentChoices.first
        else { throw TestFailure() }
        choice["title"] = .string("Resources")
        paymentChoices[0] = .object(choice)
        root["paymentAmountChoices"] = .array(paymentChoices)
        rawQuestion = .object(root)
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
            rawQuestion: exchangeRawQuestion(
                fromInitialAmount: fromInitialAmount,
                toInitialAmount: toInitialAmount
            ),
            presentation: presentation,
            questionVersion: 335
        )
    }

    private func exchangeRawQuestion(
        fromInitialAmount: Int,
        toInitialAmount: Int
    ) -> JSONValue {
        .object([
            "tag": .string("ChooseExchangeAmounts"),
            "source": .object(["tag": .string("GameSource")]),
            "investigator1Id": .string("c01001"),
            "investigator1InitialAmount": .number(.integer(Int64(fromInitialAmount))),
            "investigator2Id": .string("c01002"),
            "investigator2InitialAmount": .number(.integer(Int64(toInitialAmount))),
            "token": .string("Resource"),
        ])
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
        target: JSONValue,
        title: String = "$resources"
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
                    "title": .string(title),
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
