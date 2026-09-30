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
            ("/extra", .bool(true)),
            ("/choices/0/kind", .string("future")),
            ("/choices/0/sourceIndex", .number(.integer(1))),
            ("/choices/1/sourceIndex", .number(.integer(3))),
            ("/choiceCount", .number(.integer(3))),
            ("/tooltip", .null),
            ("/label", .null),
            ("/answer/alternateTags", .null),
            ("/selection/extra", .bool(true)),
            ("/answer/extra", .bool(true)),
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
            pointer: "/amountChoices/0/extra",
            value: .bool(true),
            note: "amountChoice is closed"
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
        try expectRepresentativeMutationRejects(
            pointer: "/choices/18/tarotCard/extra",
            value: .bool(true),
            note: "tarotCard is closed"
        )
        try expectRepresentativeMutationRejects(
            pointer: "/choices/29/cards/0/extra",
            value: .bool(true),
            note: "pileCard is closed"
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
        case .standaloneSettings, .campaignSettings, .pickDestiny,
             .campaignSpecific, .scenarioSpecific, .continueCampaign:
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
