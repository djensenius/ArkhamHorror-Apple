@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length
extension AppModelLiveGameTests {
    @Test("Q34 sends exact source index 12 and question version 34")
    func q34SemanticAdvanceActSendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let choice = try #require(prompt.choices.first { $0.index == 12 })
        let projection = try #require(
            model.liveGameState(for: gameID).lastKnownProjection
        )
        assertLegacyActionabilityParity(prompt: prompt, projection: projection)
        #expect(prompt.questionVersion == 34)
        #expect(prompt.isChoiceActionable(
            choice,
            in: projection
        ))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 12)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":12,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":34},"tag":"Answer"}"#.utf8)])
    }

    @Test("Q35 sends exact source index 0 and question version 35")
    func q35SemanticAdvanceActSendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.questionVersion == 35)
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":35},"tag":"Answer"}"#.utf8)])
    }

    @Test("Q41 sends the encounter draw's exact source index and question version")
    func q41SemanticEncounterDrawSendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-encounter-deck-draw",
            presentationFixture: "question-presentation-encounter-deck-draw",
            questionVersion: 41
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let choice = try #require(prompt.choices.first)
        let projection = try #require(
            model.liveGameState(for: gameID).lastKnownProjection
        )
        #expect(prompt.questionVersion == 41)
        #expect(prompt.displayTitle(for: choice, in: projection) == "Draw encounter card")
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":41},"tag":"Answer"}"#.utf8)])
    }

    @Test("Semantic encounter draw trusts the server descriptor after actor projection drift")
    func semanticEncounterDrawTrustsServerDescriptorBeforeSend() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-encounter-deck-draw",
            presentationFixture: "question-presentation-encounter-deck-draw",
            questionVersion: 41
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let identity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )

        let withoutActor = try semanticEnvelope(
            rawFixture: "question-encounter-deck-draw",
            presentationFixture: "question-presentation-encounter-deck-draw",
            questionVersion: 41,
            mutateGame: { $0["investigators"] = .object([:]) }
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: withoutActor.game)
        )

        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":41},"tag":"Answer"}"#.utf8)])
    }

    @Test("Q41 binds actor drift and generic descriptor downgrade")
    func semanticEncounterDrawBindingDriftBindsGenerically() throws {
        let actorDrift = try encounterDrawBinding { choice in
            choice["actorId"] = .string("c01002")
        }
        #expect(actorDrift.descriptor(forSourceIndex: 0)?.actorID == "c01002")

        let downgraded = try encounterDrawBinding { choice in
            choice["kind"] = .string("drawCard")
        }
        #expect(downgraded.descriptor(forSourceIndex: 0)?.kind == .drawCard)
    }

    @Test("Semantic advanceAct trusts the server descriptor after act projection drift")
    func semanticAdvanceActTrustsServerDescriptorBeforeSend() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let withoutAct = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            mutateGame: { $0["acts"] = .object([:]) }
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: withoutAct.game)
        )

        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 12)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":12,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":34},"tag":"Answer"}"#.utf8)])
    }

    @Test("Same raw question/version with changed descriptors rejects the stale identity")
    func changedSemanticDescriptorIsStale() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 33,
            mutatePresentation: { presentation in
                presentation["questionLabel"] = .object([
                    "kind": .string("embeddedI18n"),
                    "text": .string("$stale"),
                ])
            }
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let changed = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 33,
            mutatePresentation: { presentation in
                presentation["questionLabel"] = .object([
                    "kind": .string("embeddedI18n"),
                    "text": .string("$current"),
                ])
            }
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: changed.game)
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity.promptKey != stale.promptKey)
        #expect(
            await model.submitBasicChoice(stale, choiceIndex: 12)
                == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("A v2 ChooseN prompt remains actionable through AppModel")
    // swiftlint:disable:next function_body_length
    func chooseNGenericSingleChoicePromptIsActionable() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["fixture.first", "fixture.second"],
            chunkEntries: #"""
            {
              "fixture.first": {
                "form": "message",
                "nodes": [{"type": "text", "value": "First"}],
                "variables": []
              },
              "fixture.second": {
                "form": "message",
                "nodes": [{"type": "text", "value": "Second"}],
                "variables": []
              }
            }
            """#
        )
        model.localeCatalog = try await documents.loadSnapshot()
        model.localeCatalogRequest = LocaleCatalogRequest(
            profileID: model.selectedProfile.id,
            advertisement: documents.advertisement
        )
        let envelope = try semanticEnvelope(
            rawFixture: "question-generic-choose-n",
            presentationFixture: "question-presentation-generic-choose-n",
            questionVersion: 204
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let choice = try #require(prompt.choices.first)
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        #expect(prompt.readOnlyReason == nil)
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmitSingleChoiceAnswer)
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: choice.index)
                == .sentAwaitingSnapshot
        )
        let expected = try ContractJSON.encode(BasicChoiceAnswer(
            choice: choice.index,
            playerID: prompt.ownerID,
            questionVersion: 204
        ))
        #expect(await connection.sentData == [expected])
    }

    @Test("Multi-select prompts expose current progress and completion through AppModel")
    // swiftlint:disable:next function_body_length
    func multiSelectPromptsExposeCurrentProgressAndDone() async throws {
        let cases: [MultiSelectPromptCase] = try [
            .init(
                name: "chooseN",
                rawQuestion: fixtureJSON("question-generic-choose-n"),
                presentation: fixtureJSON("question-presentation-generic-choose-n"),
                questionVersion: 204,
                expectedHint: "Choose 1 more",
                expectedDisplayedIndices: [0, 1],
                completionIndex: nil,
                completionIsActionable: false,
                submitIndex: 0
            ),
            .init(
                name: "chooseUpToN",
                rawQuestion: fixtureJSON("question-generic-choose-up-to-n"),
                presentation: fixtureJSON("question-presentation-generic-choose-up-to-n"),
                questionVersion: 205,
                expectedHint: "Choose up to 1 more",
                expectedDisplayedIndices: [0, 1],
                completionIndex: 1,
                completionIsActionable: true,
                submitIndex: 1
            ),
            .init(
                name: "chooseSome",
                rawQuestion: fixtureJSON("question-generic-choose-some"),
                presentation: fixtureJSON("question-presentation-generic-choose-some"),
                questionVersion: 206,
                expectedHint: "Choose up to 1 more",
                expectedDisplayedIndices: [0, 1],
                completionIndex: 1,
                completionIsActionable: true,
                submitIndex: 1
            ),
            .init(
                name: "chooseSome1",
                rawQuestion: chooseSome1RawQuestion(),
                presentation: representativePresentationJSON(named: "chooseSome1"),
                questionVersion: 306,
                expectedHint: "Choose at least 1 more",
                expectedDisplayedIndices: [0],
                completionIndex: 1,
                completionIsActionable: false,
                submitIndex: 0
            ),
            .init(
                name: "chooseSomeDoneOnly",
                rawQuestion: doneOnlyRawQuestion(tag: "ChooseSome"),
                presentation: doneOnlyPresentation(questionKind: "chooseSome"),
                questionVersion: 406,
                expectedHint: "Done is available",
                expectedDisplayedIndices: [0],
                completionIndex: 0,
                completionIsActionable: true,
                submitIndex: 0
            ),
            .init(
                name: "chooseSome1DoneOnly",
                rawQuestion: doneOnlyRawQuestion(tag: "ChooseSome1", label: "$choose"),
                presentation: doneOnlyPresentation(questionKind: "chooseSome1"),
                questionVersion: 407,
                expectedHint: "Done is available",
                expectedDisplayedIndices: [0],
                completionIndex: 0,
                completionIsActionable: true,
                submitIndex: 0
            ),
            .init(
                name: "chooseOneFromEach",
                rawQuestion: fixtureJSON("question-generic-one-from-each"),
                presentation: fixtureJSON("question-presentation-generic-one-from-each"),
                questionVersion: 210,
                expectedHint: "Choose one from each group (2 groups left)",
                expectedDisplayedIndices: [0, 1],
                completionIndex: nil,
                completionIsActionable: false,
                submitIndex: 0
            ),
        ]

        for testCase in cases {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            try await installMultiSelectCatalog(on: model)
            let envelope = try semanticEnvelope(
                rawQuestion: testCase.rawQuestion,
                presentation: testCase.presentation,
                questionVersion: testCase.questionVersion
            )
            let connection = FakeGameSocketConnection()
            await connection.enqueueSendResult(.success(()))
            let gameID = await startChoiceSession(
                model: model,
                fakes: fakes,
                envelope: envelope,
                connection: connection
            )

            let prompt = try #require(model.basicChoicePresentation(for: gameID))
            let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
            #expect(prompt.questionHint() == testCase.expectedHint, "\(testCase.name) hint")
            #expect(
                prompt.questionHintAccessibilityLabel() == testCase.expectedHint,
                "\(testCase.name) accessibility hint"
            )
            #expect(
                prompt.choices.filter { prompt.shouldDisplayChoice($0) }.map(\.index)
                    == testCase.expectedDisplayedIndices,
                "\(testCase.name) displayed choices"
            )

            if let completionIndex = testCase.completionIndex {
                let completion = try #require(
                    prompt.choices.first { $0.index == completionIndex }
                )
                #expect(prompt.isCompletingSelection(completion), "\(testCase.name) completion")
                #expect(
                    prompt.isChoiceActionable(completion, in: projection)
                        == testCase.completionIsActionable,
                    "\(testCase.name) completion actionability"
                )
                #expect(prompt.systemImage(for: completion) == "checkmark.circle.fill")
                if testCase.completionIsActionable {
                    #expect(prompt.displayTitle(for: completion, in: projection) == "Done")
                    #expect(
                        prompt.accessibilityHint(for: completion, in: projection)
                            == "Finishes this selection."
                    )
                } else {
                    #expect(
                        await model.submitBasicChoice(
                            prompt.identity,
                            choiceIndex: completionIndex
                        ) == .unsupportedChoice,
                        "\(testCase.name) premature completion is rejected"
                    )
                    #expect(await connection.sentData.isEmpty)
                }
            }

            #expect(
                await model.submitBasicChoice(
                    prompt.identity,
                    choiceIndex: testCase.submitIndex
                ) == .sentAwaitingSnapshot,
                "\(testCase.name) submit"
            )
            let expected = try ContractJSON.encode(BasicChoiceAnswer(
                choice: testCase.submitIndex,
                playerID: prompt.ownerID,
                questionVersion: testCase.questionVersion
            ))
            #expect(await connection.sentData == [expected], "\(testCase.name) bytes")
        }
    }

    @Test("Multi-select progress follows the current re-asked server snapshot")
    func multiSelectProgressFollowsCurrentServerSnapshot() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        try await installMultiSelectCatalog(on: model)
        let firstEnvelope = try semanticEnvelope(
            rawQuestion: chooseNRawQuestion(amount: 2),
            presentation: chooseNPresentation(remaining: 2),
            questionVersion: 502
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: firstEnvelope,
            connection: connection
        )

        let firstPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(firstPrompt.questionHint() == "Choose 2 more")
        #expect(
            await model.submitBasicChoice(firstPrompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )

        let nextEnvelope = try semanticEnvelope(
            rawQuestion: chooseNRawQuestion(amount: 1),
            presentation: chooseNPresentation(remaining: 1),
            questionVersion: 503
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: nextEnvelope.game)
        )
        let nextPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(nextPrompt.questionVersion == 503)
        #expect(nextPrompt.questionHint() == "Choose 1 more")
        #expect(nextPrompt.displayOrderedChoices().map(\.index) == [0, 1])
    }

    @Test("Completing selection remains visible without a selection object")
    func completingSelectionWithoutSelectionIsDisplayedAndActionable() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        try await installMultiSelectCatalog(on: model)
        let envelope = try semanticEnvelope(
            rawQuestion: doneOnlyRawQuestion(tag: "ChooseOne"),
            presentation: doneOnlyPresentation(questionKind: "chooseOne", includeSelection: false),
            questionVersion: 508
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let completion = try #require(prompt.displayOrderedChoices().first)
        #expect(prompt.questionHint() == nil)
        #expect(completion.index == 0)
        #expect(prompt.isCompletingSelection(completion))
        #expect(prompt.isChoiceActionable(completion, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: completion.index)
                == .sentAwaitingSnapshot
        )
        let expected = try ContractJSON.encode(BasicChoiceAnswer(
            choice: completion.index,
            playerID: prompt.ownerID,
            questionVersion: 508
        ))
        #expect(await connection.sentData == [expected])
    }

    @Test(
        "Unsupported generic answer families require an app update through AppModel",
        arguments: [
            (
                raw: "question-generic-choose-deck",
                presentation: "question-presentation-generic-choose-deck"
            ),
        ]
    )
    func unsupportedGenericFamiliesAreUpdateRequiredInAppModel(
        raw: String,
        presentation: String
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: raw,
            presentationFixture: presentation,
            questionVersion: 204
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        #expect(prompt.readOnlyReason == .updateRequired)
        #expect(!prompt.isRenderableQuestion)
        #expect(!prompt.canSubmit)
        #expect(prompt.choices.allSatisfy { !prompt.isChoiceActionable($0, in: projection) })
    }

    @Test("Gathering raw drift outside 34-42 binds through generic rendering")
    func gatheringRawDriftOutsideRecordedSequenceBindsGenerically() throws {
        var presentationJSON = try fixtureJSON("question-presentation-gathering-act-objective")
        guard case var .object(presentationObject) = presentationJSON else {
            throw SemanticFixtureError.unexpectedShape
        }
        presentationObject["questionVersion"] = .number(.integer(68))
        presentationJSON = .object(presentationObject)
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(presentationJSON)
        )
        let driftedRaw = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: "/choices/12/ability/cardCode".split(separator: "/"),
            replacement: .string("c01109"),
            to: fixtureJSON("question-gathering-act-objective")
        )

        let binding = try presentation.bind(
            to: driftedRaw,
            expectedQuestionVersion: 68
        )
        #expect(binding.isRenderableInCurrentClient)
        #expect(binding.descriptor(forSourceIndex: 12)?.kind == .advanceAct)
    }

    @Test("Semantic localized labels are collected by authoritative source index")
    func semanticLocalizedLabelUsesDescriptorIndex() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixtureData(named: "question-gathering-act-objective")
        )
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 33,
            questionKind: .playerWindowChooseOne,
            choiceCount: 13,
            choices: [
                .init(
                    sourceIndex: 12,
                    kind: .localizedLabel,
                    actorID: nil,
                    entity: nil,
                    label: .init(kind: .embeddedI18n, text: "$continue"),
                    ability: nil,
                    cost: nil
                ),
            ]
        )
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: 33
        )

        #expect(model.choiceLabelResolutions(
            for: payload.supportedQuestion,
            semanticPresentation: bound
        ) == [12: .resolved("Continue")])
    }

    @Test("An explicit unsupported semantic kind marks the prompt update-required")
    func unsupportedSemanticKindFailsClosed() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35,
            mutateRawQuestion: { rawQuestion in
                rawQuestion = .object(["tag": .string("FutureQuestion")])
            },
            mutatePresentation: { presentation in
                presentation["questionKind"] = .string("unsupported")
                presentation["choiceCount"] = .number(.integer(0))
                presentation["choices"] = .array([])
            }
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.readOnlyReason == .updateRequired)
        #expect(!prompt.canSubmit)
    }

    @Test("Semantic localization keeps percent-bearing interpolated values verbatim")
    func semanticLocalizationPercentInterpolationsAreVerbatim() throws {
        let percentName = "50% off %@ %lld"
        let cases: [(locale: String?, expected: [String])] = [
            (nil, [
                "Fight \(percentName)",
                "Move to \(percentName)",
                "Choose \(percentName)",
                "Use Combat: \(percentName)",
                "1 clue at \(percentName)",
                percentName,
                "The text for \(percentName) is not currently available.",
            ]),
            ("de", [
                "Fight \(percentName)",
                "Zu \(percentName) bewegen",
                "\(percentName) wählen",
                "Use Combat: \(percentName)",
                "1 Hinweis bei \(percentName)",
                percentName,
                "Der Text für \(percentName) ist derzeit nicht verfügbar.",
            ]),
        ]
        let projection = try percentInterpolationProjection(locationLabel: percentName)
        for testCase in cases {
            let prompt = try percentInterpolationPrompt(
                locale: testCase.locale,
                cardName: percentName
            )
            let titles = prompt.choices.map { prompt.displayTitle(for: $0, in: projection) }
            let disabledReason = percentDisabledLabelReason(
                title: percentName,
                in: prompt
            )
            #expect(titles + [disabledReason] == testCase.expected)
        }
    }

    @Test("An empty supported semantic question still requires an app update")
    func emptySupportedSemanticQuestionFailsClosed() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 36,
            mutateRawQuestion: { rawQuestion in
                rawQuestion = .object([
                    "tag": .string("ChooseOne"),
                    "choices": .array([]),
                ])
            },
            mutatePresentation: { presentation in
                presentation["questionVersion"] = .number(.integer(36))
                presentation["choiceCount"] = .number(.integer(0))
                presentation["choices"] = .array([])
            }
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.readOnlyReason == .updateRequired)
        #expect(!prompt.isRenderableQuestion)
        #expect(prompt.choices.isEmpty)
        #expect(!prompt.canSubmit)
    }

    private struct MultiSelectPromptCase {
        let name: String
        let rawQuestion: JSONValue
        let presentation: JSONValue
        let questionVersion: Int
        let expectedHint: String
        let expectedDisplayedIndices: [Int]
        let completionIndex: Int?
        let completionIsActionable: Bool
        let submitIndex: Int
    }

    private func installMultiSelectCatalog(on model: AppModel) async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["fixture.first", "fixture.second", "group.one", "group.two", "a", "done"],
            chunkEntries: #"""
            {
              "fixture.first": {
                "form": "message",
                "nodes": [{"type": "text", "value": "First"}],
                "variables": []
              },
              "fixture.second": {
                "form": "message",
                "nodes": [{"type": "text", "value": "Second"}],
                "variables": []
              },
              "group.one": {
                "form": "message",
                "nodes": [{"type": "text", "value": "Group one"}],
                "variables": []
              },
              "group.two": {
                "form": "message",
                "nodes": [{"type": "text", "value": "Group two"}],
                "variables": []
              },
              "a": {
                "form": "message",
                "nodes": [{"type": "text", "value": "A"}],
                "variables": []
              },
              "done": {
                "form": "message",
                "nodes": [{"type": "text", "value": "Done"}],
                "variables": []
              }
            }
            """#
        )
        model.localeCatalog = try await documents.loadSnapshot()
        model.localeCatalogRequest = LocaleCatalogRequest(
            profileID: model.selectedProfile.id,
            advertisement: documents.advertisement
        )
    }

    private func chooseSome1RawQuestion() -> JSONValue {
        .object([
            "tag": .string("ChooseSome1"),
            "label": .string("$choose"),
            "choices": .array([
                .object([
                    "tag": .string("Label"),
                    "label": .string("$a"),
                    "messages": .array([]),
                ]),
                .object([
                    "tag": .string("Done"),
                    "label": .string("$done"),
                ]),
            ]),
        ])
    }

    private func chooseNRawQuestion(amount: Int) -> JSONValue {
        .object([
            "tag": .string("ChooseN"),
            "amount": .number(.integer(Int64(amount))),
            "choices": .array([
                .object([
                    "tag": .string("Label"),
                    "label": .string("$fixture.first"),
                    "messages": .array([]),
                ]),
                .object([
                    "tag": .string("Label"),
                    "label": .string("$fixture.second"),
                    "messages": .array([]),
                ]),
            ]),
        ])
    }

    private func chooseNPresentation(remaining: Int) -> JSONValue {
        let count = Int64(remaining)
        return .object([
            "answer": .object(["kind": .string("singleChoice"), "tag": .string("Answer")]),
            "choiceCount": .number(.integer(2)),
            "choices": .array([
                localizedChoice(sourceIndex: 0, text: "$fixture.first"),
                localizedChoice(sourceIndex: 1, text: "$fixture.second"),
            ]),
            "protocolVersion": .number(.integer(2)),
            "questionKind": .string("chooseN"),
            "selection": .object([
                "max": .number(.integer(count)),
                "min": .number(.integer(count)),
            ]),
        ])
    }

    private func doneOnlyRawQuestion(tag: String, label: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "tag": .string(tag),
            "choices": .array([
                .object([
                    "tag": .string("Done"),
                    "label": .string("$done"),
                ]),
            ]),
        ]
        if let label {
            object["label"] = .string(label)
        }
        return .object(object)
    }

    private func doneOnlyPresentation(
        questionKind: String,
        includeSelection: Bool = true
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "answer": .object(["kind": .string("singleChoice"), "tag": .string("Answer")]),
            "choiceCount": .number(.integer(1)),
            "choices": .array([
                localizedChoice(sourceIndex: 0, text: "$done", completesSelection: true),
            ]),
            "protocolVersion": .number(.integer(2)),
            "questionKind": .string(questionKind),
        ]
        if includeSelection {
            object["selection"] = .object([
                "max": .number(.integer(0)),
                "min": .number(.integer(0)),
            ])
        }
        return .object(object)
    }

    private func localizedChoice(
        sourceIndex: Int,
        text: String,
        completesSelection: Bool = false
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string("localizedLabel"),
            "label": .object([
                "kind": .string("embeddedI18n"),
                "text": .string(text),
            ]),
            "selectable": .bool(true),
            "sourceIndex": .number(.integer(Int64(sourceIndex))),
        ]
        if completesSelection {
            object["completesSelection"] = .bool(true)
        }
        return .object(object)
    }

    private func representativePresentationJSON(named name: String) throws -> JSONValue {
        let representatives = try fixtureJSON("question-presentation-representatives")
        guard case let .object(root) = representatives,
              case let .array(entries)? = root["presentations"]
        else { throw SemanticFixtureError.unexpectedShape }
        for entry in entries {
            guard case let .object(object) = entry,
                  object["name"] == .string(name),
                  let presentation = object["presentation"]
            else { continue }
            return presentation
        }
        throw SemanticFixtureError.unexpectedShape
    }

    private func semanticEnvelope(
        rawQuestion: JSONValue,
        presentation: JSONValue,
        questionVersion: Int
    ) throws -> GetGameEnvelope {
        var envelope = try ContractJSON.decode(
            JSONValue.self,
            from: fixtureData(named: "get-game")
        )
        guard case var .object(root) = envelope,
              case var .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"],
              case var .object(presentationObject) = presentation
        else {
            throw SemanticFixtureError.unexpectedShape
        }
        presentationObject["questionVersion"] = .number(.integer(Int64(questionVersion)))
        game["question"] = .object([playerID: rawQuestion])
        game["questionPresentation"] = .object([playerID: .object(presentationObject)])
        game["scenarioSteps"] = .number(.integer(Int64(questionVersion)))
        root["game"] = .object(game)
        envelope = .object(root)
        return try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(envelope)
        )
    }

    enum SemanticFixtureError: Error {
        case unexpectedShape
    }

    // swiftlint:disable:next function_body_length
    private func percentInterpolationPrompt(
        locale: String?,
        cardName: String
    ) throws -> BasicChoicePromptPresentation {
        let rawChoices: [JSONValue] = (0 ..< 6).map { .object(["tag": .string("Choice\($0)")]) }
        let rawQuestion: JSONValue = .object([
            "tag": .string("ChooseOne"),
            "choices": .array(rawChoices),
        ])
        let choices: [QuestionPresentation.Choice] = [
            .init(
                sourceIndex: 0,
                kind: .fight,
                entity: .init(kind: .cardCode, id: "c01001")
            ),
            .init(
                sourceIndex: 1,
                kind: .move,
                entity: .init(kind: .cardCode, id: "c01001")
            ),
            .init(
                sourceIndex: 2,
                kind: .chooseTarget,
                entity: .init(kind: .cardCode, id: "c01001")
            ),
            .init(
                sourceIndex: 3,
                kind: .skillLabel,
                label: .init(kind: .embeddedI18n, text: cardName),
                skillType: .combat
            ),
            .init(
                sourceIndex: 4,
                kind: .costLabel,
                cost: .groupClue(
                    amount: .fixed(1),
                    scope: .location("d5a66e84-c729-4066-8475-d8a155609025")
                )
            ),
            .init(
                sourceIndex: 5,
                kind: .localizedLabel,
                label: .init(kind: .embeddedI18n, text: cardName)
            ),
        ]
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 701,
            questionKind: .chooseOne,
            choiceCount: rawChoices.count,
            choices: choices
        )
        let bound = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 701)
        let cardCode = try CardCode("c01001")
        let cardCatalog = CardCatalogSnapshot(namesByCode: [
            cardCode: CardName(title: cardName, subtitle: nil),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 701,
                rawQuestion: rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: bound,
            semanticLocaleIdentifier: locale,
            cardCatalog: cardCatalog,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func percentInterpolationProjection(locationLabel: String) throws -> BoardProjection {
        var envelope = try fixtureJSON("get-game")
        guard case var .object(root) = envelope,
              case var .object(game)? = root["game"],
              case var .object(locations)? = game["locations"],
              case var .object(location)? = locations[
                  "d5a66e84-c729-4066-8475-d8a155609025"
              ]
        else { throw SemanticFixtureError.unexpectedShape }
        location["label"] = .string(locationLabel)
        locations["d5a66e84-c729-4066-8475-d8a155609025"] = .object(location)
        game["locations"] = .object(locations)
        root["game"] = .object(game)
        envelope = .object(root)
        let decoded = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(envelope)
        )
        return BoardProjectionBuilder.makeProjection(from: decoded.game)
    }

    private func percentDisabledLabelReason(
        title: String,
        in prompt: BasicChoicePromptPresentation
    ) -> String {
        let row = BasicChoiceAmountPromptRow(
            id: "percent-label",
            title: title,
            minBound: 0,
            maxBound: 1,
            labelUnavailableReason: .catalog(.notAdvertised)
        )
        let amountPrompt = BasicChoiceAmountPrompt(
            kind: .amounts,
            legend: "Choose amounts",
            rows: [row],
            target: .total(1)
        )
        return amountPrompt.disabledReason(
            for: ["percent-label": 1],
            in: prompt
        ) ?? ""
    }

    private func assertLegacyActionabilityParity(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) {
        let legacy = BasicChoicePromptPresentation(
            identity: prompt.identity,
            question: prompt.question,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let semanticActionability = prompt.choices.map {
            prompt.isChoiceActionable($0, in: projection)
        }
        let legacyActionability = legacy.choices.map {
            legacy.isChoiceActionable($0, in: projection)
        }
        let allSemanticChoicesActionable = semanticActionability.allSatisfy(\.self)
        #expect(allSemanticChoicesActionable)
        #expect(!legacyActionability[12])
    }

    func encounterDrawBinding(
        mutateChoice: (inout [String: JSONValue]) throws -> Void
    ) throws -> BoundQuestionPresentation {
        var presentation = try fixtureJSON("question-presentation-encounter-deck-draw")
        guard case var .object(presentationObject) = presentation,
              case var .array(choices)? = presentationObject["choices"],
              case var .object(choice) = choices.first
        else { throw SemanticFixtureError.unexpectedShape }
        try mutateChoice(&choice)
        choices[0] = .object(choice)
        presentationObject["choices"] = .array(choices)
        presentation = .object(presentationObject)
        return try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(presentation)
        ).bind(
            to: fixtureJSON("question-encounter-deck-draw"),
            expectedQuestionVersion: 41
        )
    }

    func semanticEnvelope(
        rawFixture: String,
        presentationFixture: String,
        questionVersion: Int,
        mutateRawQuestion: ((inout JSONValue) throws -> Void)? = nil,
        mutateGame: ((inout [String: JSONValue]) throws -> Void)? = nil,
        mutatePresentation: ((inout [String: JSONValue]) throws -> Void)? = nil
    ) throws -> GetGameEnvelope {
        var envelope = try ContractJSON.decode(
            JSONValue.self,
            from: fixtureData(named: "get-game")
        )
        guard case var .object(root) = envelope,
              case var .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"]
        else {
            throw SemanticFixtureError.unexpectedShape
        }
        var presentation = try fixtureJSON(presentationFixture)
        guard case var .object(presentationObject) = presentation else {
            throw SemanticFixtureError.unexpectedShape
        }
        presentationObject["questionVersion"] = .number(.integer(Int64(questionVersion)))
        try mutatePresentation?(&presentationObject)
        presentation = .object(presentationObject)
        var rawQuestion = try fixtureJSON(rawFixture)
        try mutateRawQuestion?(&rawQuestion)
        game["question"] = .object([
            playerID: rawQuestion,
        ])
        game["questionPresentation"] = .object([
            playerID: presentation,
        ])
        game["scenarioSteps"] = .number(.integer(Int64(questionVersion)))
        try mutateGame?(&game)
        root["game"] = .object(game)
        envelope = .object(root)
        return try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(envelope)
        )
    }

    private func fixtureJSON(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: name))
    }
}

private enum SemanticEncounterDrawWrapper: CaseIterable {
    case label
    case payCost
    case source

    func wrapping(_ question: JSONValue) -> JSONValue {
        switch self {
        case .label:
            .object([
                "tag": .string("QuestionLabel"),
                "label": .string("Draw"),
                "card": .null,
                "question": question,
            ])
        case .payCost:
            .object([
                "tag": .string("PayCostQuestion"),
                "cost": .object(["tag": .string("Free")]),
                "question": question,
            ])
        case .source:
            .object([
                "tag": .string("QuestionWithSource"),
                "source": .object(["tag": .string("GameSource")]),
                "tooltip": .null,
                "question": question,
            ])
        }
    }
}
