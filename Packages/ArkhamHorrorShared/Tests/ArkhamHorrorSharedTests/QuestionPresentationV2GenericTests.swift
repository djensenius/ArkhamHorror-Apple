// swiftlint:disable file_length type_body_length function_body_length nesting
// swiftlint:disable line_length cyclomatic_complexity
@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Question presentation v2 generic contract")
struct QuestionPresentationV2GenericTests {
    private let genericNames = [
        "choose-amounts",
        "choose-deck",
        "choose-n",
        "choose-some",
        "choose-up-to-n",
        "cost-ability-window",
        "invalid-info",
        "one-at-a-time-auto",
        "one-from-each",
        "payment-amounts",
        "read",
        "skill-label",
        "wrapped",
    ]

    @Test("Every vendored generic v2 presentation decodes and binds structurally")
    func genericFixturesDecodeAndBind() throws {
        for name in genericNames {
            let presentation = try presentationFixture("question-presentation-generic-\(name)")
            #expect(presentation.protocolVersion == 2)
            #expect(presentation.genericSupport != .deferred)
            let binding = try presentation.bind(
                to: rawFixture("question-generic-\(name)"),
                expectedQuestionVersion: presentation.questionVersion
            )
            #expect(binding.rawChoices.count == presentation.choiceCount)
            #expect(Set(presentation.choices.map(\.sourceIndex)) == Set(0 ..< presentation.choiceCount))
        }
    }

    @Test("Every representative v2 presentation entry decodes")
    func representativeFixturesDecode() throws {
        struct Representatives: Decodable {
            struct Entry: Decodable {
                let name: String
                let presentation: QuestionPresentation
            }

            let presentations: [Entry]
        }
        let representatives = try ContractJSON.decode(
            Representatives.self,
            from: fixture("question-presentation-representatives")
        )
        #expect(representatives.presentations.count == 37)
        for entry in representatives.presentations {
            #expect(entry.presentation.protocolVersion == 2, "\(entry.name)")
            #expect(
                entry.presentation.genericSupport == expectedGenericSupport(
                    for: entry.presentation.answer
                ),
                "\(entry.name)"
            )
        }
    }

    private struct GenericSupportExpectation {
        let fixtureName: String
        let support: QuestionPresentation.GenericSupport
        let supportsChoiceList: Bool
    }

    @Test("Generic support and current choice-list rendering are exact per question kind")
    func genericSupportMatrix() throws {
        let expectations: [GenericSupportExpectation] = [
            .init(fixtureName: "question-presentation-generic-choose-n", support: .singleChoice, supportsChoiceList: true),
            .init(fixtureName: "question-presentation-generic-choose-some", support: .singleChoice, supportsChoiceList: true),
            .init(fixtureName: "question-presentation-generic-choose-up-to-n", support: .singleChoice, supportsChoiceList: true),
            .init(fixtureName: "question-presentation-generic-one-from-each", support: .singleChoice, supportsChoiceList: true),
            .init(fixtureName: "question-presentation-generic-read", support: .singleChoice, supportsChoiceList: true),
            .init(fixtureName: "question-presentation-generic-choose-amounts", support: .amounts, supportsChoiceList: false),
            .init(fixtureName: "question-presentation-generic-payment-amounts", support: .payment, supportsChoiceList: false),
            .init(fixtureName: "question-presentation-generic-choose-deck", support: .deck, supportsChoiceList: false),
        ]
        for expectation in expectations {
            let presentation = try presentationFixture(expectation.fixtureName)
            #expect(presentation.genericSupport == expectation.support, "\(expectation.fixtureName)")
            #expect(
                presentation.supportsCurrentGenericChoiceList == expectation.supportsChoiceList,
                "\(expectation.fixtureName)"
            )
        }
    }

    @Test("ContinueCampaign only renders when CampaignStepAnswer is advertised")
    func continueCampaignRequiresCampaignStepAnswerTag() throws {
        let rawQuestion: JSONValue = .object(["tag": .string("ContinueCampaign")])
        let supported = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 1,
            questionKind: .continueCampaign,
            choiceCount: 0,
            choices: [],
            answer: .continueCampaign(tags: ["CampaignStepAnswer"])
        )
        let unsupported = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 1,
            questionKind: .continueCampaign,
            choiceCount: 0,
            choices: [],
            answer: .continueCampaign(tags: ["RetireInvestigatorAnswer"])
        )

        #expect(supported.genericSupport == .continuation)
        #expect(try supported.bind(
            to: rawQuestion,
            expectedQuestionVersion: 1
        ).isRenderableInCurrentClient)
        #expect(unsupported.genericSupport == .deferred)
        #expect(try !((unsupported.bind(
            to: rawQuestion,
            expectedQuestionVersion: 1
        )).isRenderableInCurrentClient))
    }

    @Test("Non-single-answer presentations cannot submit as basic single choices")
    func canSubmitSingleChoiceAnswerFollowsGenericSupport() throws {
        let singleChoice = try prompt(fixtureName: "question-presentation-generic-read")
        #expect(singleChoice.canSubmitSingleChoiceAnswer)
        let amounts = try prompt(fixtureName: "question-presentation-generic-choose-amounts")
        #expect(!amounts.canSubmitSingleChoiceAnswer)
        let deck = try prompt(fixtureName: "question-presentation-generic-choose-deck")
        #expect(!deck.canSubmitSingleChoiceAnswer)
        let chooseN = try prompt(fixtureName: "question-presentation-generic-choose-n")
        #expect(chooseN.canSubmitSingleChoiceAnswer)
    }

    @Test("Generic rendering still respects selectable on non-info choices")
    func genericChoiceListRespectsSelectableForEveryKind() throws {
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(investigators: [
                BoardTestFixtures.investigatorID("c01001"):
                    BoardTestFixtures.investigator(
                        id: BoardTestFixtures.investigatorID("c01001")
                    ),
            ])
        )
        let selectablePrompt = try drawCardPrompt(selectable: true)
        let selectableChoice = try #require(selectablePrompt.choices.first)
        #expect(selectablePrompt.isChoiceActionable(selectableChoice, in: projection))

        let disabledPrompt = try drawCardPrompt(selectable: false)
        let disabledChoice = try #require(disabledPrompt.choices.first)
        #expect(!disabledPrompt.isChoiceActionable(disabledChoice, in: projection))
    }

    @Test("V2 structural mutations reject")
    func structuralMutationsReject() throws {
        let base = try JSONValueMutationObject(
            fixtureData: fixture("question-presentation-generic-choose-n")
        )
        let mutations: [(String, JSONValue?)] = [
            ("/protocolVersion", .number(.integer(1))),
            ("/questionKind", .string("future")),
            ("/choices/0/kind", .string("future")),
            ("/choices/0/sourceIndex", .number(.integer(1))),
            ("/choices/1/sourceIndex", .number(.integer(3))),
            ("/choiceCount", .number(.integer(3))),
            ("/tooltip", .null),
            ("/label", .null),
            ("/answer/alternateTags", .null),
            ("/selection/min", nil),
        ]
        for (pointer, value) in mutations {
            #expect(throws: DecodingError.self, "\(pointer)") {
                try ContractJSON.decode(
                    QuestionPresentation.self,
                    from: base.replacing(pointer: pointer, with: value).data()
                )
            }
        }
    }

    @Test("V2 nested schema constraints reject")
    func nestedSchemaConstraintsReject() throws {
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-choose-amounts",
            pointer: "/target",
            value: .null,
            note: "chooseAmounts target is required non-null"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-choose-amounts",
            pointer: "/answer/kind",
            value: .string("singleChoice"),
            note: "answer/kind must match questionKind"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-invalid-info",
            pointer: "/answer",
            value: .object([
                "kind": .string("amounts"),
                "tag": .string("AmountsAnswer"),
            ]),
            note: "single-choice question kinds must use the single-choice Answer envelope"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-choose-amounts",
            pointer: "/label",
            value: nil,
            note: "chooseAmounts label is required"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-choose-amounts",
            pointer: "/resolveTarget",
            value: .string("untagged"),
            note: "resolveTarget must be tagged JSON"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-choose-amounts",
            pointer: "/amountChoices/0/choiceId",
            value: nil,
            note: "amountChoice.choiceId is required"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-invalid-info",
            pointer: "/choices/0/selectable",
            value: .bool(true),
            note: "invalidLabel must be non-selectable"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-invalid-info",
            pointer: "/choices/1/selectable",
            value: .bool(true),
            note: "info must be non-selectable"
        )
        try expectPresentationMutationRejects(
            fixture: "question-presentation-generic-invalid-info",
            pointer: "/choices/1/flavorText/title",
            value: nil,
            note: "flavorText.title is nullable but required"
        )
        try expectRepresentativeMutationRejects(
            pointer: "/choices/0/key",
            value: .string("untagged"),
            note: "choice key must be tagged JSON"
        )
        try expectRepresentativeMutationRejects(
            pointer: "/choices/0/target",
            value: .string("untagged"),
            note: "choice target must be tagged JSON"
        )
        try expectRepresentativeMutationRejects(
            pointer: "/choices/0/step",
            value: .string("untagged"),
            note: "choice step must be a typed chaos-bag step"
        )
        try expectRepresentativeMutationRejects(
            pointer: "/choices/29/cards/0/cardOwner",
            value: nil,
            note: "pileCard.cardOwner is nullable but required"
        )
    }

    @Test("Schema-permitted nulls decode only at their documented locations")
    func schemaPermittedNullsDecode() throws {
        try expectPresentationMutationDecodes(
            fixture: "question-presentation-generic-payment-amounts",
            pointer: "/target",
            value: .null
        )
        let invalidInfo = try presentationFixture("question-presentation-generic-invalid-info")
        #expect(invalidInfo.choices[1].flavorText?.title == nil)
        try expectRepresentativeMutationDecodes(
            pointer: "/choices/29/cards/0/cardOwner",
            value: .null
        )
        let nullableSpecificValue = specificPresentation(
            kind: "pickCampaignSpecific",
            answerTag: "CampaignSpecificAnswer"
        ).replacingOccurrences(of: #""value":{"tag":"Value"}"#, with: #""value":null"#)
        _ = try ContractJSON.decode(
            QuestionPresentation.self,
            from: Data(nullableSpecificValue.utf8)
        )
    }

    @Test("Additive prompt fields decode, bind, and preserve answer bytes")
    func additivePromptFieldsDecodeBindAndPreserveAnswerBytes() throws {
        for testCase in try additiveToleranceCases() {
            let basePresentation = try ContractJSON.decode(
                QuestionPresentation.self,
                from: testCase.presentationData
            )
            let baseRawQuestion = try ContractJSON.decode(
                JSONValue.self,
                from: testCase.rawData
            )
            let baseBinding = try basePresentation.bind(
                to: baseRawQuestion,
                expectedQuestionVersion: basePresentation.questionVersion
            )
            let baseAnswer = try answerBytes(for: basePresentation)

            let mutatedPresentationData = try mutatedData(
                testCase.presentationData,
                mutations: testCase.presentationMutations
            )
            let mutatedRawData = try mutatedData(
                testCase.rawData,
                mutations: testCase.rawMutations
            )
            let mutatedPresentation = try ContractJSON.decode(
                QuestionPresentation.self,
                from: mutatedPresentationData
            )
            let mutatedRawQuestion = try ContractJSON.decode(
                JSONValue.self,
                from: mutatedRawData
            )
            let mutatedBinding = try mutatedPresentation.bind(
                to: mutatedRawQuestion,
                expectedQuestionVersion: mutatedPresentation.questionVersion
            )

            #expect(mutatedBinding.rawChoices == baseBinding.rawChoices, "\(testCase.name) raw choices")
            #expect(
                mutatedBinding.isRenderableInCurrentClient == testCase.isRenderableInCurrentClient,
                "\(testCase.name) renderability"
            )
            let mutatedAnswer = try answerBytes(for: mutatedPresentation)
            if testCase.expectsExchangeSourceEcho {
                let sentSource = try exchangeAnswerSource(from: mutatedAnswer)
                let mutatedServerSource = try presentationSourceRaw(from: mutatedPresentationData)
                #expect(sentSource == mutatedServerSource, "\(testCase.name) source echo")
            } else {
                #expect(mutatedAnswer == baseAnswer, "\(testCase.name) answer bytes")
            }
        }
    }

    @Test("Additive-field tolerance still requires fields each raw family uses")
    func additiveRawQuestionToleranceStillRequiresFields() throws {
        let missingFieldCases = [
            (
                name: "ChooseOne choices",
                rawJSON: #"{"tag":"ChooseOne"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseOne question")
            ),
            (
                name: "PlayerWindowChooseOne choices",
                rawJSON: #"{"tag":"PlayerWindowChooseOne"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed PlayerWindowChooseOne question")
            ),
            (
                name: "WindowChooseOne choices",
                rawJSON: #"{"tag":"WindowChooseOne"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed WindowChooseOne question")
            ),
            (
                name: "ChooseSome choices",
                rawJSON: #"{"tag":"ChooseSome"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseSome question")
            ),
            (
                name: "ChooseOneAtATime choices",
                rawJSON: #"{"tag":"ChooseOneAtATime"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseOneAtATime question")
            ),
            (
                name: "ChooseN amount",
                rawJSON: #"{"tag":"ChooseN","choices":[{}]}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseN question")
            ),
            (
                name: "ChooseUpToN amount",
                rawJSON: #"{"tag":"ChooseUpToN","choices":[{}]}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseUpToN question")
            ),
            (
                name: "ChooseSome1 label",
                rawJSON: #"{"tag":"ChooseSome1","choices":[{}]}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseSome1 question")
            ),
            (
                name: "ChooseOneAtATimeWithAuto label",
                rawJSON: #"{"tag":"ChooseOneAtATimeWithAuto","choices":[{}]}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseOneAtATimeWithAuto question")
            ),
            (
                name: "QuestionLabel question",
                rawJSON: #"{"tag":"QuestionLabel","label":"x","card":null}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed QuestionLabel wrapper")
            ),
            (
                name: "PayCostQuestion cost",
                rawJSON: #"{"tag":"PayCostQuestion","question":{"tag":"ChooseDeck"}}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed PayCostQuestion wrapper")
            ),
            (
                name: "QuestionWithSource tooltip",
                rawJSON: #"{"tag":"QuestionWithSource","source":{"tag":"GameSource"},"question":{"tag":"ChooseDeck"}}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed QuestionWithSource wrapper")
            ),
            (
                name: "ChooseOneFromEach groups",
                rawJSON: #"{"tag":"ChooseOneFromEach"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseOneFromEach question")
            ),
            (
                name: "ChoosePaymentAmounts paymentAmountChoices",
                rawJSON: #"{"tag":"ChoosePaymentAmounts","label":"$pay","paymentAmountTargetValue":null}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChoosePaymentAmounts question")
            ),
            (
                name: "ChooseAmounts target",
                rawJSON: #"{"tag":"ChooseAmounts","label":"$amount","amountTargetValue":null,"amountChoices":[]}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseAmounts question")
            ),
            (
                name: "ChooseExchangeAmounts token",
                rawJSON: #"{"tag":"ChooseExchangeAmounts","source":{"tag":"GameSource"},"investigator1Id":"c01001","investigator1InitialAmount":3,"investigator2Id":"c01002","investigator2InitialAmount":1}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseExchangeAmounts question")
            ),
            // Tag-only noChoice constructors have no branch-local required field beyond
            // the shared raw-question tag used for dispatch, so their missing-tag rows
            // assert the common tagged-object guard.
            (
                name: "ChooseDeck tag",
                rawJSON: #"{"family":"ChooseDeck"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Raw question must be a tagged object")
            ),
            (
                name: "ChooseUpgradeDeck tag",
                rawJSON: #"{"family":"ChooseUpgradeDeck"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Raw question must be a tagged object")
            ),
            (
                name: "ChooseJoinDeck usedInvestigators",
                rawJSON: #"{"tag":"ChooseJoinDeck"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseJoinDeck question")
            ),
            (
                name: "ChooseOneWizard confirmLabel",
                rawJSON: #"{"tag":"ChooseOneWizard","flavorText":{},"wizardChoices":[{}],"backLabel":"$back"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed ChooseOneWizard question")
            ),
            (
                name: "PickSupplies pointsRemaining",
                rawJSON: #"{"tag":"PickSupplies","chosenSupplies":[],"choices":[{}],"resupply":false}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed PickSupplies question")
            ),
            (
                name: "PickDestiny drawings",
                rawJSON: #"{"tag":"PickDestiny"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed PickDestiny question")
            ),
            (
                name: "PickScenarioSettings tag",
                rawJSON: #"{"family":"PickScenarioSettings"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Raw question must be a tagged object")
            ),
            (
                name: "PickCampaignSettings tag",
                rawJSON: #"{"family":"PickCampaignSettings"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Raw question must be a tagged object")
            ),
            (
                name: "ContinueCampaign tag",
                rawJSON: #"{"family":"ContinueCampaign"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Raw question must be a tagged object")
            ),
            (
                name: "DropDown options",
                rawJSON: #"{"tag":"DropDown"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed DropDown question")
            ),
            (
                name: "PickCampaignSpecific contents",
                rawJSON: #"{"tag":"PickCampaignSpecific"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed PickCampaignSpecific question")
            ),
            (
                name: "PickScenarioSpecific contents",
                rawJSON: #"{"tag":"PickScenarioSpecific"}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed PickScenarioSpecific question")
            ),
            (
                name: "Read flavorText",
                rawJSON: #"{"tag":"Read","readChoices":{"tag":"BasicReadChoices","contents":[{}]},"readCards":null}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed Read question")
            ),
            (
                name: "Read readChoices contents",
                rawJSON: #"{"tag":"Read","flavorText":{},"readChoices":{"tag":"BasicReadChoices"},"readCards":null}"#,
                error: QuestionPresentationBindingError.invalidRawQuestion("Malformed Read question")
            ),
        ]
        for testCase in missingFieldCases {
            #expect(throws: testCase.error, "\(testCase.name): \(testCase.rawJSON)") {
                _ = try QuestionPresentationRawQuestionDeriver.derive(
                    ContractJSON.decode(JSONValue.self, from: Data(testCase.rawJSON.utf8))
                )
            }
        }
    }

    @Test("Answer tag advertisements ignore unknown extras but require sendable tags")
    func answerTagAdvertisementsAreTolerantButRequired() throws {
        let singleChoice = #"{"kind":"singleChoice","tag":"Answer","alternateTags":["FutureAnswer","OrderedAnswer"]}"#
        #expect(
            try ContractJSON.decode(
                QuestionPresentation.Answer.self,
                from: Data(singleChoice.utf8)
            ) == .singleChoice(alternateTags: ["OrderedAnswer"])
        )

        let deck = #"{"kind":"deck","tags":["FutureDeckAnswer","DeckAnswer","DeckListAnswer"]}"#
        #expect(
            try ContractJSON.decode(
                QuestionPresentation.Answer.self,
                from: Data(deck.utf8)
            ) == .deck(tags: ["DeckAnswer"])
        )

        let continuation = #"{"kind":"continueCampaign","tags":["CampaignStepAnswer","FutureAnswer"]}"#
        #expect(
            try ContractJSON.decode(
                QuestionPresentation.Answer.self,
                from: Data(continuation.utf8)
            ) == .continueCampaign(tags: ["CampaignStepAnswer"])
        )

        for invalid in [
            #"{"kind":"future","tag":"Answer"}"#,
            #"{"kind":"deck","tags":["FutureDeckAnswer"]}"#,
            #"{"kind":"deck","tags":["DeckListAnswer"]}"#,
            #"{"kind":"continueCampaign","tags":["FutureAnswer"]}"#,
        ] {
            #expect(throws: DecodingError.self, "\(invalid)") {
                try ContractJSON.decode(QuestionPresentation.Answer.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test("Previously closed additive presentation fields now decode")
    func additivePresentationFieldMutationsDecode() throws {
        try expectPresentationMutationDecodes(
            fixture: "question-presentation-generic-choose-n",
            pointer: "/extra",
            value: .bool(true)
        )
        try expectPresentationMutationDecodes(
            fixture: "question-presentation-generic-choose-n",
            pointer: "/selection/extra",
            value: .bool(true)
        )
        try expectPresentationMutationDecodes(
            fixture: "question-presentation-generic-choose-n",
            pointer: "/answer/extra",
            value: .bool(true)
        )
        try expectPresentationMutationDecodes(
            fixture: "question-presentation-generic-choose-amounts",
            pointer: "/amountChoices/0/extra",
            value: .bool(true)
        )
        try expectRepresentativeMutationDecodes(
            pointer: "/choices/18/tarotCard/extra",
            value: .bool(true)
        )
        try expectRepresentativeMutationDecodes(
            pointer: "/choices/29/cards/0/extra",
            value: .bool(true)
        )
    }

    @Test("Raw server question encodings without vendored raw fixtures bind to matching v2 presentations")
    func rawServerQuestionEncodingsWithoutFixturesBind() throws {
        // Arkham/Question.hs:198 derives record-field JSON with defaultOptions.
        try bindRawPresentationPair(
            raw: singleRawQuestion(tag: "ChooseOneAtATime"),
            presentation: singleChoicePresentation(
                kind: "chooseOneAtATime",
                selection: (min: 1, max: 1)
            )
        )
        // Arkham/Question.hs:196 derives a label plus choices record.
        try bindRawPresentationPair(
            raw: #"{"tag":"ChooseSome1","label":"$choose","choices":[{"tag":"Label","label":"$ok","messages":[]}]}"#,
            presentation: singleChoicePresentation(
                kind: "chooseSome1",
                selection: (min: 1, max: 1)
            )
        )
        // Arkham/Question.hs:218 is a nullary constructor encoded as {tag}.
        try bindRawPresentationPair(
            raw: #"{"tag":"ChooseUpgradeDeck"}"#,
            presentation: deckPresentation(kind: "chooseUpgradeDeck")
        )
        // Arkham/Question.hs:222 derives the usedInvestigators record field.
        try bindRawPresentationPair(
            raw: #"{"tag":"ChooseJoinDeck","usedInvestigators":["c01001"]}"#,
            presentation: deckPresentation(
                kind: "chooseJoinDeck",
                usedInvestigators: ["c01001"]
            )
        )
        // Arkham/Question.hs:240-241 derives PickSupplies record fields.
        try bindRawPresentationPair(
            raw: #"{"tag":"PickSupplies","pointsRemaining":2,"chosenSupplies":["Provisions"],"choices":[{"tag":"Label","label":"$supply","messages":[]}],"resupply":false}"#,
            presentation: pickSuppliesPresentation()
        )
        // Arkham/Question.hs:242 derives the drawings record field.
        try bindRawPresentationPair(
            raw: #"{"tag":"PickDestiny","drawings":[]}"#,
            presentation: pickDestinyPresentation()
        )
        // Arkham/Question.hs:243 derives the options record field.
        try bindRawPresentationPair(
            raw: #"{"tag":"DropDown","options":[["$option",{"tag":"Value"}]]}"#,
            presentation: singleChoicePresentation(kind: "dropDown")
        )
        // Arkham/Question.hs:244 is a nullary constructor encoded as {tag}.
        try bindRawPresentationPair(
            raw: #"{"tag":"PickScenarioSettings"}"#,
            presentation: settingsPresentation(
                kind: "pickScenarioSettings",
                answerKind: "standaloneSettings",
                answerTag: "StandaloneSettingsAnswer"
            )
        )
        // Arkham/Question.hs:245 is a nullary constructor encoded as {tag}.
        try bindRawPresentationPair(
            raw: #"{"tag":"PickCampaignSettings"}"#,
            presentation: settingsPresentation(
                kind: "pickCampaignSettings",
                answerKind: "campaignSettings",
                answerTag: "CampaignSettingsAnswer"
            )
        )
        // Arkham/Question.hs:246 positional constructor encodes as {tag,contents}.
        try bindRawPresentationPair(
            raw: #"{"tag":"PickCampaignSpecific","contents":["key",{"tag":"Value"}]}"#,
            presentation: specificPresentation(kind: "pickCampaignSpecific", answerTag: "CampaignSpecificAnswer")
        )
        // Arkham/Question.hs:247 positional constructor encodes as {tag,contents}.
        try bindRawPresentationPair(
            raw: #"{"tag":"PickScenarioSpecific","contents":["key",{"tag":"Value"}]}"#,
            presentation: specificPresentation(kind: "pickScenarioSpecific", answerTag: "ScenarioSpecificAnswer")
        )
        // Arkham/Question.hs:248-254 derives these record field names via
        // deriveToJSON defaultOptions ''Question at Question.hs:362.
        try bindRawPresentationPair(
            raw: #"""
            {
              "tag":"ChooseExchangeAmounts",
              "source":{"tag":"GameSource"},
              "investigator1Id":"c01001",
              "investigator1InitialAmount":3,
              "investigator2Id":"c01002",
              "investigator2InitialAmount":1,
              "token":"ResourceToken"
            }
            """#,
            presentation: #"""
            {
              "protocolVersion":2,
              "questionVersion":1,
              "questionKind":"chooseExchangeAmounts",
              "choiceCount":0,
              "choices":[],
              "answer":{"kind":"exchangeAmounts","tag":"ExchangeAmountsAnswer"},
              "source":{"raw":{"tag":"GameSource"}},
              "fromInvestigator":"c01001",
              "fromInitialAmount":3,
              "toInvestigator":"c01002",
              "toInitialAmount":1,
              "token":"ResourceToken"
            }
            """#
        )
        // Arkham/Question.hs:256 is a nullary constructor encoded as {tag}.
        try bindRawPresentationPair(
            raw: #"{"tag":"ContinueCampaign"}"#,
            presentation: #"""
            {
              "protocolVersion":2,
              "questionVersion":1,
              "questionKind":"continueCampaign",
              "choiceCount":0,
              "choices":[],
              "answer":{"kind":"continueCampaign","tags":["CampaignStepAnswer"]}
            }
            """#
        )
        // Arkham/Question.hs:234-238 names the choice field wizardChoices.
        try bindRawPresentationPair(
            raw: #"""
            {
              "tag":"ChooseOneWizard",
              "flavorText":{"title":null,"body":[]},
              "wizardChoices":[{"tag":"Label","label":"$ok","messages":[]}],
              "confirmLabel":"$confirm",
              "backLabel":"$back"
            }
            """#,
            presentation: #"""
            {
              "protocolVersion":2,
              "questionVersion":1,
              "questionKind":"chooseOneWizard",
              "choiceCount":1,
              "choices":[{"sourceIndex":0,"kind":"wizardChoice","selectable":true,"label":{"kind":"embeddedI18n","text":"$ok"}}],
              "answer":{"kind":"singleChoice","tag":"Answer"},
              "flavorText":{"title":null,"body":[]},
              "confirmLabel":{"kind":"embeddedI18n","text":"$confirm"},
              "backLabel":{"kind":"embeddedI18n","text":"$back"}
            }
            """#
        )
    }

    private struct AdditiveToleranceCase {
        let name: String
        let presentationData: Data
        let rawData: Data
        let presentationMutations: [AdditiveMutation]
        let rawMutations: [AdditiveMutation]
        let isRenderableInCurrentClient: Bool
        let expectsExchangeSourceEcho: Bool

        init(
            name: String,
            presentationData: Data,
            rawData: Data,
            presentationMutations: [AdditiveMutation],
            rawMutations: [AdditiveMutation],
            isRenderableInCurrentClient: Bool,
            expectsExchangeSourceEcho: Bool = false
        ) {
            self.name = name
            self.presentationData = presentationData
            self.rawData = rawData
            self.presentationMutations = presentationMutations
            self.rawMutations = rawMutations
            self.isRenderableInCurrentClient = isRenderableInCurrentClient
            self.expectsExchangeSourceEcho = expectsExchangeSourceEcho
        }
    }

    private struct AdditiveMutation {
        let pointer: String
        let value: JSONValue
    }

    private func additiveToleranceCases() throws -> [AdditiveToleranceCase] {
        let singleChoiceExtras = [
            AdditiveMutation(pointer: "/extra", value: .bool(true)),
            AdditiveMutation(pointer: "/choices/0/extra", value: .bool(true)),
            AdditiveMutation(pointer: "/answer/extra", value: .bool(true)),
        ]
        return try [
            .init(
                name: "direct choices",
                presentationData: fixture("question-presentation-generic-cost-ability-window"),
                rawData: fixture("question-generic-cost-ability-window"),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/choices/1/entity/extra", value: .string("entity-addition")),
                    .init(pointer: "/choices/1/ability/extra", value: .string("ability-addition")),
                    .init(pointer: "/choices/1/cost/extra", value: .string("cost-addition")),
                    .init(pointer: "/answer/alternateTags", value: .array([.string("FutureAnswer"), .string("OrderedAnswer")])),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "counted choices",
                presentationData: fixture("question-presentation-generic-choose-n"),
                rawData: fixture("question-generic-choose-n"),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/selection/extra", value: .bool(true)),
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "labeled choices",
                presentationData: fixture("question-presentation-generic-one-at-a-time-auto"),
                rawData: fixture("question-generic-one-at-a-time-auto"),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/selection/extra", value: .bool(true)),
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "wrapped question",
                presentationData: fixture("question-presentation-generic-wrapped"),
                rawData: fixture("question-generic-wrapped"),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/questionLabel/extra", value: .string("question-label-addition")),
                    .init(pointer: "/payCost/extra", value: .bool(true)),
                    .init(pointer: "/questionSource/extra", value: .bool(true)),
                    .init(pointer: "/questionSource/raw/extra", value: .bool(true)),
                    .init(pointer: "/choices/0/label/extra", value: .string("choice-label-addition")),
                ],
                rawMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/source/extra", value: .bool(true)),
                    .init(pointer: "/question/extra", value: .bool(true)),
                ],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "amounts",
                presentationData: fixture("question-presentation-generic-choose-amounts"),
                rawData: fixture("question-generic-choose-amounts"),
                presentationMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/answer/extra", value: .bool(true)),
                    .init(pointer: "/label/extra", value: .string("label-addition")),
                    .init(pointer: "/target/extra", value: .bool(true)),
                    .init(pointer: "/resolveTarget/extra", value: .bool(true)),
                    .init(pointer: "/amountChoices/0/extra", value: .bool(true)),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "payment amounts",
                presentationData: fixture("question-presentation-generic-payment-amounts"),
                rawData: fixture("question-generic-payment-amounts"),
                presentationMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/answer/extra", value: .bool(true)),
                    .init(pointer: "/label/extra", value: .string("label-addition")),
                    .init(pointer: "/target/extra", value: .bool(true)),
                    .init(pointer: "/paymentChoices/0/extra", value: .bool(true)),
                    .init(pointer: "/paymentChoices/0/title/extra", value: .string("title-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "exchange amounts",
                presentationData: Data(exchangePresentationJSON.utf8),
                rawData: Data(exchangeRawJSON.utf8),
                presentationMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/answer/extra", value: .bool(true)),
                    .init(pointer: "/source/extra", value: .bool(true)),
                    .init(pointer: "/source/raw/extra", value: .bool(true)),
                ],
                rawMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/source/extra", value: .bool(true)),
                ],
                isRenderableInCurrentClient: true,
                expectsExchangeSourceEcho: true
            ),
            .init(
                name: "exchange amounts nested source",
                presentationData: Data(proxyExchangePresentationJSON.utf8),
                rawData: Data(proxyExchangeRawJSON.utf8),
                presentationMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/answer/extra", value: .bool(true)),
                    .init(pointer: "/source/raw/source/extra", value: .string("child-addition")),
                ],
                rawMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/source/source/extra", value: .string("child-addition")),
                ],
                isRenderableInCurrentClient: true,
                expectsExchangeSourceEcho: true
            ),
            .init(
                name: "deck",
                presentationData: fixture("question-presentation-generic-choose-deck"),
                rawData: fixture("question-generic-choose-deck"),
                presentationMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/answer/extra", value: .bool(true)),
                    .init(pointer: "/answer/tags", value: .array([.string("FutureDeckAnswer"), .string("DeckAnswer"), .string("DeckListAnswer")])),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: false
            ),
            .init(
                name: "continue campaign",
                presentationData: Data(continueCampaignPresentationJSON.utf8),
                rawData: Data(#"{"tag":"ContinueCampaign"}"#.utf8),
                presentationMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/answer/extra", value: .bool(true)),
                    .init(pointer: "/answer/tags", value: .array([.string("CampaignStepAnswer"), .string("FutureAnswer")])),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "one from each",
                presentationData: fixture("question-presentation-generic-one-from-each"),
                rawData: fixture("question-generic-one-from-each"),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "wizard",
                presentationData: Data(wizardPresentationJSON.utf8),
                rawData: Data(wizardRawJSON.utf8),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                    .init(pointer: "/flavorText/extra", value: .bool(true)),
                    .init(pointer: "/confirmLabel/extra", value: .string("confirm-addition")),
                    .init(pointer: "/backLabel/extra", value: .string("back-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "pick supplies",
                presentationData: Data(pickSuppliesPresentationJSON.utf8),
                rawData: Data(pickSuppliesRawJSON.utf8),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "dropdown",
                presentationData: Data(singleChoicePresentation(kind: "dropDown").utf8),
                rawData: Data(#"{"tag":"DropDown","options":[["$option",{"tag":"Value"}]]}"#.utf8),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                ],
                rawMutations: [.init(pointer: "/extra", value: .bool(true))],
                isRenderableInCurrentClient: true
            ),
            .init(
                name: "read",
                presentationData: fixture("question-presentation-generic-read"),
                rawData: fixture("question-generic-read"),
                presentationMutations: singleChoiceExtras + [
                    .init(pointer: "/choices/0/label/extra", value: .string("label-addition")),
                    .init(pointer: "/flavorText/extra", value: .bool(true)),
                ],
                rawMutations: [
                    .init(pointer: "/extra", value: .bool(true)),
                    .init(pointer: "/readChoices/extra", value: .bool(true)),
                ],
                isRenderableInCurrentClient: true
            ),
        ]
    }

    private func mutatedData(
        _ data: Data,
        mutations: [AdditiveMutation]
    ) throws -> Data {
        var mutationObject = try JSONValueMutationObject(fixtureData: data)
        for mutation in mutations {
            mutationObject = try mutationObject.replacing(pointer: mutation.pointer, with: mutation.value)
        }
        return try mutationObject.data()
    }

    private func exchangeAnswerSource(from answerData: Data) throws -> JSONValue {
        let value = try ContractJSON.decode(JSONValue.self, from: answerData)
        guard case let .object(object) = value,
              let source = object["source"]
        else { throw MutationError.invalidPointer }
        return source
    }

    private func presentationSourceRaw(from presentationData: Data) throws -> JSONValue {
        let value = try ContractJSON.decode(JSONValue.self, from: presentationData)
        guard case let .object(object) = value,
              case let .object(source)? = object["source"],
              let raw = source["raw"]
        else { throw MutationError.invalidPointer }
        return raw
    }

    private func answerBytes(for presentation: QuestionPresentation) throws -> Data {
        let playerID = try fixedPlayerID()
        switch presentation.answer {
        case .singleChoice:
            return try ContractJSON.encode(BasicChoiceAnswer(
                choice: 0,
                playerID: playerID,
                questionVersion: presentation.questionVersion
            ))
        case .amounts:
            let choiceID = try #require(presentation.amountChoices?.first?.choiceID)
            return try ContractJSON.encode(AmountsAnswer(
                amounts: [choiceID: 0],
                playerID: playerID,
                questionVersion: presentation.questionVersion
            ))
        case .paymentAmounts:
            let choiceID = try #require(presentation.paymentChoices?.first?.choiceID)
            return try ContractJSON.encode(PaymentAmountsAnswer(
                amounts: [choiceID: 0],
                playerID: playerID,
                questionVersion: presentation.questionVersion
            ))
        case .exchangeAmounts:
            let source = try #require(presentation.source?.raw)
            let fromInvestigator = try #require(presentation.fromInvestigator)
            let toInvestigator = try #require(presentation.toInvestigator)
            let token = try #require(presentation.token)
            return try ContractJSON.encode(ExchangeAmountsAnswer(
                source: source,
                fromInvestigator: fromInvestigator,
                toInvestigator: toInvestigator,
                token: token,
                amount: 0
            ))
        case .deck:
            let deckID = try fixedDeckID()
            return try ContractJSON.encode(DeckAnswer(
                deckId: deckID,
                playerId: playerID
            ))
        case .continueCampaign:
            return try ContractJSON.encode(CampaignStepAnswer(
                contents: .object(["tag": .string("NextStep")])
            ))
        case .standaloneSettings, .campaignSettings, .pickDestiny,
             .campaignSpecific, .scenarioSpecific:
            throw MutationError.invalidPointer
        }
    }

    private func fixedPlayerID() throws -> PlayerID {
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001") else {
            throw MutationError.invalidPointer
        }
        return PlayerID(uuid)
    }

    private func fixedDeckID() throws -> DeckID {
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000002") else {
            throw MutationError.invalidPointer
        }
        return DeckID(uuid)
    }

    private var exchangeRawJSON: String {
        #"{"tag":"ChooseExchangeAmounts","source":{"tag":"GameSource"},"investigator1Id":"c01001","investigator1InitialAmount":3,"investigator2Id":"c01002","investigator2InitialAmount":1,"token":"ResourceToken"}"#
    }

    private var exchangePresentationJSON: String {
        #"{"protocolVersion":2,"questionVersion":1,"questionKind":"chooseExchangeAmounts","choiceCount":0,"choices":[],"answer":{"kind":"exchangeAmounts","tag":"ExchangeAmountsAnswer"},"source":{"raw":{"tag":"GameSource"}},"fromInvestigator":"c01001","fromInitialAmount":3,"toInvestigator":"c01002","toInitialAmount":1,"token":"ResourceToken"}"#
    }

    private var proxyExchangeRawJSON: String {
        #"{"tag":"ChooseExchangeAmounts","source":{"tag":"ProxySource","source":{"tag":"CardSource","contents":"01001"},"originalSource":{"tag":"GameSource"}},"investigator1Id":"c01001","investigator1InitialAmount":3,"investigator2Id":"c01002","investigator2InitialAmount":1,"token":"ResourceToken"}"#
    }

    private var proxyExchangePresentationJSON: String {
        #"{"protocolVersion":2,"questionVersion":1,"questionKind":"chooseExchangeAmounts","choiceCount":0,"choices":[],"answer":{"kind":"exchangeAmounts","tag":"ExchangeAmountsAnswer"},"source":{"raw":{"tag":"ProxySource","source":{"tag":"CardSource","contents":"01001"},"originalSource":{"tag":"GameSource"}}},"fromInvestigator":"c01001","fromInitialAmount":3,"toInvestigator":"c01002","toInitialAmount":1,"token":"ResourceToken"}"#
    }

    private var continueCampaignPresentationJSON: String {
        #"{"protocolVersion":2,"questionVersion":1,"questionKind":"continueCampaign","choiceCount":0,"choices":[],"answer":{"kind":"continueCampaign","tags":["CampaignStepAnswer"]}}"#
    }

    private var wizardRawJSON: String {
        #"{"tag":"ChooseOneWizard","flavorText":{"title":null,"body":[]},"wizardChoices":[{"tag":"Label","label":"$ok","messages":[]}],"confirmLabel":"$confirm","backLabel":"$back"}"#
    }

    private var wizardPresentationJSON: String {
        #"{"protocolVersion":2,"questionVersion":1,"questionKind":"chooseOneWizard","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"wizardChoice","selectable":true,"label":{"kind":"embeddedI18n","text":"$ok"}}],"answer":{"kind":"singleChoice","tag":"Answer"},"flavorText":{"title":null,"body":[]},"confirmLabel":{"kind":"embeddedI18n","text":"$confirm"},"backLabel":{"kind":"embeddedI18n","text":"$back"}}"#
    }

    private var pickSuppliesRawJSON: String {
        #"{"tag":"PickSupplies","pointsRemaining":2,"chosenSupplies":["Provisions"],"choices":[{"tag":"Label","label":"$supply","messages":[]}],"resupply":false}"#
    }

    private var pickSuppliesPresentationJSON: String {
        #"{"protocolVersion":2,"questionVersion":1,"questionKind":"pickSupplies","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"localizedLabel","selectable":true,"label":{"kind":"embeddedI18n","text":"$supply"}}],"answer":{"kind":"singleChoice","tag":"Answer"},"pointsRemaining":2,"chosenSupplies":["Provisions"],"resupply":false}"#
    }

    private func expectPresentationMutationRejects(
        fixture name: String,
        pointer: String,
        value: JSONValue?,
        note: String
    ) throws {
        let base = try JSONValueMutationObject(fixtureData: fixture(name))
        #expect(throws: DecodingError.self, "\(note)") {
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: base.replacing(pointer: pointer, with: value).data()
            )
        }
    }

    private func expectPresentationMutationDecodes(
        fixture name: String,
        pointer: String,
        value: JSONValue?
    ) throws {
        let base = try JSONValueMutationObject(fixtureData: fixture(name))
        _ = try ContractJSON.decode(
            QuestionPresentation.self,
            from: base.replacing(pointer: pointer, with: value).data()
        )
    }

    private func expectRepresentativeMutationRejects(
        pointer: String,
        value: JSONValue?,
        note: String
    ) throws {
        #expect(throws: DecodingError.self, "\(note)") {
            _ = try mutatedRepresentative(pointer: pointer, value: value)
        }
    }

    private func expectRepresentativeMutationDecodes(
        pointer: String,
        value: JSONValue?
    ) throws {
        _ = try mutatedRepresentative(pointer: pointer, value: value)
    }

    private func mutatedRepresentative(
        pointer: String,
        value: JSONValue?
    ) throws -> QuestionPresentation {
        struct Representatives: Decodable {
            struct Entry: Decodable {
                let name: String
                let presentation: JSONValue
            }

            let presentations: [Entry]
        }
        let representatives = try ContractJSON.decode(
            Representatives.self,
            from: fixture("question-presentation-representatives")
        )
        var presentation = try #require(representatives.presentations.first?.presentation)
        try presentation.replace(pointer: pointer, with: value)
        return try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(presentation)
        )
    }

    private func bindRawPresentationPair(raw: String, presentation: String) throws {
        let rawQuestion = try ContractJSON.decode(JSONValue.self, from: Data(raw.utf8))
        let decodedPresentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: Data(presentation.utf8)
        )
        let binding = try decodedPresentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: decodedPresentation.questionVersion
        )
        #expect(binding.rawChoices.count == decodedPresentation.choiceCount)
    }

    private func singleRawQuestion(tag: String) -> String {
        #"{"tag":"\#(tag)","choices":[{"tag":"Label","label":"$ok","messages":[]}]}"#
    }

    private func singleChoicePresentation(
        kind: String,
        selection: (min: Int, max: Int)? = nil
    ) -> String {
        let selectionFields = selection.map {
            #", "selection":{"min":\#($0.min),"max":\#($0.max)}"#
        } ?? ""
        return #"""
        {
          "protocolVersion":2,
          "questionVersion":1,
          "questionKind":"\#(kind)",
          "choiceCount":1,
          "choices":[{"sourceIndex":0,"kind":"localizedLabel","selectable":true,"label":{"kind":"embeddedI18n","text":"$ok"}}],
          "answer":{"kind":"singleChoice","tag":"Answer"}
          \#(selectionFields)
        }
        """#
    }

    private func deckPresentation(
        kind: String,
        usedInvestigators: [String]? = nil
    ) -> String {
        let usedInvestigatorsField = usedInvestigators.map {
            let encoded = $0.map { #""\#($0)""# }.joined(separator: ",")
            return #", "usedInvestigators":[\#(encoded)]"#
        } ?? ""
        return #"""
        {
          "protocolVersion":2,
          "questionVersion":1,
          "questionKind":"\#(kind)",
          "choiceCount":0,
          "choices":[],
          "answer":{"kind":"deck","tags":["DeckAnswer","DeckListAnswer"]}
          \#(usedInvestigatorsField)
        }
        """#
    }

    private func pickSuppliesPresentation() -> String {
        #"""
        {
          "protocolVersion":2,
          "questionVersion":1,
          "questionKind":"pickSupplies",
          "choiceCount":1,
          "choices":[{"sourceIndex":0,"kind":"localizedLabel","selectable":true,"label":{"kind":"embeddedI18n","text":"$supply"}}],
          "answer":{"kind":"singleChoice","tag":"Answer"},
          "pointsRemaining":2,
          "chosenSupplies":["Provisions"],
          "resupply":false
        }
        """#
    }

    private func pickDestinyPresentation() -> String {
        #"""
        {
          "protocolVersion":2,
          "questionVersion":1,
          "questionKind":"pickDestiny",
          "choiceCount":0,
          "choices":[],
          "answer":{"kind":"pickDestiny","tag":"PickDestinyAnswer"},
          "drawings":[{"scenario":{"tag":"CampaignScope"},"tarot":{"facing":"Upright","arcana":"The Fool"}}]
        }
        """#
    }

    private func settingsPresentation(
        kind: String,
        answerKind: String,
        answerTag: String
    ) -> String {
        #"""
        {
          "protocolVersion":2,
          "questionVersion":1,
          "questionKind":"\#(kind)",
          "choiceCount":0,
          "choices":[],
          "answer":{"kind":"\#(answerKind)","tag":"\#(answerTag)"}
        }
        """#
    }

    private func specificPresentation(kind: String, answerTag: String) -> String {
        let answerKind = kind == "pickCampaignSpecific" ? "campaignSpecific" : "scenarioSpecific"
        return #"""
        {
          "protocolVersion":2,
          "questionVersion":1,
          "questionKind":"\#(kind)",
          "choiceCount":0,
          "choices":[],
          "answer":{"kind":"\#(answerKind)","tag":"\#(answerTag)"},
          "key":"key",
          "value":{"tag":"Value"}
        }
        """#
    }

    private func drawCardPrompt(selectable: Bool) throws -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string("ChooseOne"),
            "choices": .array([
                .object(["tag": .string("DrawCards"), "contents": .number(.integer(1))]),
            ]),
        ])
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 1,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [
                .init(sourceIndex: 0, kind: .drawCard, selectable: selectable, actorID: "c01001"),
            ]
        )
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 1)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: GameID(UUID()),
                ownerID: PlayerID(UUID()),
                questionVersion: 1,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func prompt(fixtureName: String) throws -> BasicChoicePromptPresentation {
        let presentation = try presentationFixture(fixtureName)
        let rawName = fixtureName.replacingOccurrences(
            of: "question-presentation-",
            with: "question-"
        )
        let rawQuestion = try rawFixture(rawName)
        let binding = try presentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: presentation.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: GameID(UUID()),
                ownerID: PlayerID(UUID()),
                questionVersion: presentation.questionVersion,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            readOnlyReason: presentation.supportsCurrentGenericChoiceList ? nil : .updateRequired,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func expectedGenericSupport(
        for answer: QuestionPresentation.Answer
    ) -> QuestionPresentation.GenericSupport {
        switch answer {
        case .singleChoice:
            .singleChoice
        case .amounts:
            .amounts
        case .paymentAmounts:
            .payment
        case .exchangeAmounts:
            .exchange
        case .deck:
            .deck
        case let .continueCampaign(tags):
            tags.contains("CampaignStepAnswer") ? .continuation : .deferred
        case .pickDestiny:
            .pickDestiny
        case .campaignSpecific:
            .campaignSpecific
        case .standaloneSettings, .campaignSettings, .scenarioSpecific:
            .campaignSettings
        }
    }

    private func presentationFixture(_ name: String) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    private func rawFixture(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixture(name))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}

private struct JSONValueMutationObject {
    private let original: JSONValue

    init(fixtureData: Data) throws {
        original = try ContractJSON.decode(JSONValue.self, from: fixtureData)
    }

    func replacing(pointer: String, with value: JSONValue?) throws -> Self {
        var copy = original
        try copy.replace(pointer: pointer, with: value)
        return Self(original: copy)
    }

    func data() throws -> Data {
        try ContractJSON.encode(original)
    }

    private init(original: JSONValue) {
        self.original = original
    }
}

private extension JSONValue {
    mutating func replace(pointer: String, with value: JSONValue?) throws {
        var parts = pointer.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first?.isEmpty == true else { throw MutationError.invalidPointer }
        parts.removeFirst()
        try replace(parts: parts, with: value)
    }

    mutating func replace(parts: [String], with value: JSONValue?) throws {
        guard let head = parts.first else { throw MutationError.invalidPointer }
        if parts.count == 1 {
            switch self {
            case var .object(object):
                object[head] = value
                self = .object(object)
            case var .array(array):
                guard let index = Int(head), array.indices.contains(index), let value else {
                    throw MutationError.invalidPointer
                }
                array[index] = value
                self = .array(array)
            default:
                throw MutationError.invalidPointer
            }
            return
        }
        switch self {
        case var .object(object):
            guard var child = object[head] else { throw MutationError.invalidPointer }
            try child.replace(parts: Array(parts.dropFirst()), with: value)
            object[head] = child
            self = .object(object)
        case var .array(array):
            guard let index = Int(head), array.indices.contains(index) else {
                throw MutationError.invalidPointer
            }
            var child = array[index]
            try child.replace(parts: Array(parts.dropFirst()), with: value)
            array[index] = child
            self = .array(array)
        default:
            throw MutationError.invalidPointer
        }
    }
}

private enum MutationError: Error {
    case invalidPointer
}

// swiftlint:enable file_length type_body_length function_body_length nesting line_length cyclomatic_complexity
