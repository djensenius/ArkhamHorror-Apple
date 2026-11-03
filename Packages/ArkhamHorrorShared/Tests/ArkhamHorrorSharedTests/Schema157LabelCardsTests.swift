@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 replaced the `QuestionLabel` wrapper's single nullable `card` with a
/// `labelCards` array. These tests decode the captured 0.1.57 bytes in
/// `Fixtures/Schema157Drift` (see its PROVENANCE.md) next to the pre-0.1.57 bytes in
/// `Fixtures/LegacyContract`, so one build accepts either server shape and rejects a mix.
@Suite("Schema 0.1.57 QuestionLabel labelCards")
struct Schema157LabelCardsTests {
    /// Assignment prompts the raw basic-choice parser recognizes directly.
    static let parsedAssignmentFixtures = [
        "question-agenda-horror-assignment",
        "question-enemy-attack-damage-assignment",
        "question-enemy-attack-remaining-damage-assignment",
        "question-enemy-attack-remaining-horror-assignment",
    ]

    /// Assignment prompts that render through their bound semantic presentation.
    static let semanticAssignmentFixtures = [
        "question-gathering-attic-horror-assignment",
        "question-gathering-cellar-damage-assignment",
    ]

    static let assignmentFixtures = parsedAssignmentFixtures + semanticAssignmentFixtures

    @Test("Captured 0.1.57 assignment prompts parse exactly like their pre-0.1.57 bytes")
    func assignmentPromptsAcceptBothShapes() throws {
        for name in Self.parsedAssignmentFixtures {
            let schemaValue = try Schema157Fixtures.value(name)
            #expect(try Self.labelQuestion(schemaValue)["labelCards"] == .array([]), "\(name)")
            let legacyValue = try Schema157Fixtures.legacyValue(name)
            #expect(try Self.labelQuestion(legacyValue)["card"] == .null, "\(name)")

            let schemaQuestion = try #require(
                BasicChoiceParser.parseQuestion(schemaValue).supportedQuestion, "\(name)"
            )
            let legacyQuestion = try #require(
                BasicChoiceParser.parseQuestion(legacyValue).supportedQuestion, "\(name)"
            )
            #expect(schemaQuestion.kind == .questionWithSource, "\(name)")
            #expect(!schemaQuestion.choices.isEmpty, "\(name)")
            #expect(Self.allSupported(schemaQuestion), "\(name)")
            let schemaContents = schemaQuestion.choices.map(\.content)
            #expect(schemaContents == legacyQuestion.choices.map(\.content), "\(name)")
            let schemaTitles = schemaQuestion.choices.map(\.title)
            #expect(schemaTitles == legacyQuestion.choices.map(\.title), "\(name)")
        }
    }

    @Test("Captured 0.1.57 Gathering assignments bind like the pre-0.1.57 bytes")
    func semanticAssignmentPromptsBindBothShapes() throws {
        for name in Self.semanticAssignmentFixtures {
            let presentation = try ContractJSON.decode(
                QuestionPresentation.self,
                from: Schema157Fixtures.contractData(
                    name.replacingOccurrences(of: "question-", with: "question-presentation-")
                )
            )
            let schemaValue = try Schema157Fixtures.value(name)
            #expect(try Self.labelQuestion(schemaValue)["labelCards"] == .array([]), "\(name)")
            let legacyValue = try Schema157Fixtures.legacyValue(name)
            var renderedChoices: [[JSONValue]] = []
            for raw in [schemaValue, legacyValue] {
                let binding = try presentation.bind(
                    to: raw, expectedQuestionVersion: presentation.questionVersion
                )
                #expect(binding.rawChoices.count == 1, "\(name)")
                #expect(binding.isRenderableInCurrentClient, "\(name)")
                let prompt = Schema157Fixtures.prompt(
                    rawQuestion: raw, presentation: presentation, binding: binding
                )
                #expect(prompt.isRenderableQuestion, "\(name)")
                renderedChoices.append(binding.rawChoices)
            }
            #expect(renderedChoices[0] == renderedChoices[1], "\(name)")

            let both = try Self.mutatingLabel(schemaValue) { $0["card"] = .null }
            #expect(throws: QuestionPresentationBindingError.self, "\(name)") {
                _ = try presentation.bind(
                    to: both, expectedQuestionVersion: presentation.questionVersion
                )
            }
        }
    }

    @Test("Captured 0.1.57 enemy attack assignment keeps its exact choice titles")
    func enemyAttackAssignmentTitles() throws {
        let question = try #require(BasicChoiceParser.parseQuestion(
            Schema157Fixtures.value("question-enemy-attack-damage-assignment")
        ).supportedQuestion)
        #expect(question.choices.map(\.index) == [0, 1])
        #expect(question.choices.map(\.title) == ["Assign 1 damage", "Assign 1 horror"])
    }

    @Test("Assignment prompts with both card and labelCards, or a named card, fail closed")
    func assignmentPromptsRejectMixedOrCardBearingShapes() throws {
        for name in Self.parsedAssignmentFixtures {
            let both = try Self.mutatingLabel(Schema157Fixtures.value(name)) {
                $0["card"] = .null
            }
            #expect(!Self.parsesSupported(both), "\(name)")
            let neither = try Self.mutatingLabel(Schema157Fixtures.value(name)) {
                $0["labelCards"] = nil
            }
            #expect(!Self.parsesSupported(neither), "\(name)")
            let named = try Self.mutatingLabel(Schema157Fixtures.value(name)) {
                $0["labelCards"] = .array([.string("c01001")])
            }
            #expect(!Self.parsesSupported(named), "\(name)")
        }
    }

    @Test("QuestionLabel card codes accept exactly one wire shape")
    func questionLabelCardCodesHelper() {
        func cards(_ fields: [String: JSONValue]) -> [String]? {
            JSONValue.questionLabelCardCodes(fields.merging(["label": .string("$label")]) { $1 })
        }
        let twoCards: JSONValue = .array([.string("c01001"), .string("c01002")])
        #expect(cards(["card": .null]) == [])
        #expect(cards(["card": .string("c01120")]) == ["c01120"])
        #expect(cards(["labelCards": .array([])]) == [])
        #expect(cards(["labelCards": twoCards]) == ["c01001", "c01002"])
        #expect(cards([:]) == nil)
        #expect(cards(["card": .null, "labelCards": .array([])]) == nil)
        #expect(cards(["labelCards": .array([.null])]) == nil)
        #expect(cards(["labelCards": .string("c01001")]) == nil)
        #expect(cards(["card": .array([])]) == nil)
    }

    @Test("Captured 0.1.57 generic wrapped prompt binds and renders like the legacy bytes")
    func genericWrappedBindsBothShapes() throws {
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: Schema157Fixtures.contractData("question-presentation-generic-wrapped")
        )
        for raw in try [
            Schema157Fixtures.value("question-generic-wrapped"),
            Schema157Fixtures.legacyValue("question-generic-wrapped"),
        ] {
            let binding = try presentation.bind(
                to: raw, expectedQuestionVersion: presentation.questionVersion
            )
            #expect(binding.rawChoices.count == 1)
            #expect(binding.isRenderableInCurrentClient)
            let prompt = Schema157Fixtures.prompt(
                rawQuestion: raw, presentation: presentation, binding: binding
            )
            #expect(prompt.isRenderableQuestion)
            #expect(prompt.choices.map(\.index) == [0])
        }
        let wrapped = try Schema157Fixtures.value("question-generic-wrapped")
        #expect(try Self.innerLabel(wrapped)["labelCards"] == .array([.string("c01120")]))
    }

    @Test("Generic wrapped prompts with both or neither card fields fail to bind")
    func genericWrappedRejectsMixedShapes() throws {
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: Schema157Fixtures.contractData("question-presentation-generic-wrapped")
        )
        let wrapped = try Schema157Fixtures.value("question-generic-wrapped")
        let both = try Self.mutatingInnerLabel(wrapped) { $0["card"] = .string("c01120") }
        let neither = try Self.mutatingInnerLabel(wrapped) { $0["labelCards"] = nil }
        let wrongType = try Self.mutatingInnerLabel(wrapped) {
            $0["labelCards"] = .array([.number(.integer(1))])
        }
        for raw in [both, neither, wrongType] {
            #expect(throws: QuestionPresentationBindingError.self) {
                _ = try presentation.bind(
                    to: raw, expectedQuestionVersion: presentation.questionVersion
                )
            }
        }
    }

    @Test("Labelled ChooseDeck prompts match in either card shape and reject mixed shapes")
    func labelledChooseDeckAcceptsBothShapes() {
        func wrapper(_ fields: [String: JSONValue]) -> JSONValue {
            .object(fields.merging([
                "tag": .string("QuestionLabel"),
                "label": .string("$chooseDeck"),
                "question": .object(["tag": .string("ChooseDeck")]),
            ]) { current, _ in current })
        }
        #expect(LiveChooseDeckQuestion.matches(wrapper(["card": .null])))
        #expect(LiveChooseDeckQuestion.matches(wrapper(["card": .string("c01001")])))
        #expect(LiveChooseDeckQuestion.matches(wrapper(["labelCards": .array([])])))
        #expect(LiveChooseDeckQuestion.matches(wrapper([
            "labelCards": .array([.string("c01001"), .string("c01002")]),
        ])))
        #expect(!LiveChooseDeckQuestion.matches(wrapper([:])))
        let mixed = wrapper(["card": .null, "labelCards": .array([])])
        #expect(!LiveChooseDeckQuestion.matches(mixed))
    }

    @Test("Representative questionLabel-many presentation carries every label card")
    func presentationLabelCardsDecodeAndRoundTrip() throws {
        let entry = try Schema157Fixtures.representative(named: "questionLabel-many")
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self, from: ContractJSON.encode(entry)
        )
        #expect(presentation.cardCode == "c01001")
        #expect(presentation.labelCards == ["c01001", "c01002"])
        #expect(presentation.questionLabel?.text == "$wrapped.many")
        let reencoded = try LosslessJSONParser.parse(ContractJSON.encode(presentation))
        #expect(reencoded == entry)
    }

    @Test("Presentation labelCards must hold two or more cards led by cardCode")
    func presentationLabelCardsValidation() throws {
        let entry = try Schema157Fixtures.representative(named: "questionLabel-many")
        guard case var .object(object) = entry else {
            Issue.record("Expected object")
            return
        }
        for invalid: JSONValue in [
            .array([.string("c01001")]),
            .array([.string("c01002"), .string("c01001")]),
            .string("c01001"),
        ] {
            object["labelCards"] = invalid
            #expect(throws: DecodingError.self) {
                _ = try ContractJSON.decode(
                    QuestionPresentation.self,
                    from: ContractJSON.encode(JSONValue.object(object))
                )
            }
        }
    }

    // MARK: - Helpers

    private static func allSupported(_ question: BasicChoiceQuestion) -> Bool {
        question.choices.allSatisfy(\.isSupported)
    }

    private static func parsesSupported(_ value: JSONValue) -> Bool {
        guard let question = BasicChoiceParser.parseQuestion(value).supportedQuestion else {
            return false
        }
        return allSupported(question)
    }

    private static func labelQuestion(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case let .object(root) = value, case let .object(label)? = root["question"] else {
            throw Schema157Fixtures.Failure.shape
        }
        return label
    }

    private static func mutatingLabel(
        _ value: JSONValue,
        _ mutate: (inout [String: JSONValue]) -> Void
    ) throws -> JSONValue {
        guard case var .object(root) = value else { throw Schema157Fixtures.Failure.shape }
        var label = try labelQuestion(value)
        mutate(&label)
        root["question"] = .object(label)
        return .object(root)
    }

    private static func innerLabel(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case let .object(root) = value,
              case let .object(payCost)? = root["question"],
              case let .object(label)? = payCost["question"]
        else { throw Schema157Fixtures.Failure.shape }
        return label
    }

    private static func mutatingInnerLabel(
        _ value: JSONValue,
        _ mutate: (inout [String: JSONValue]) -> Void
    ) throws -> JSONValue {
        guard case var .object(root) = value, case var .object(payCost)? = root["question"] else {
            throw Schema157Fixtures.Failure.shape
        }
        var label = try innerLabel(value)
        mutate(&label)
        payCost["question"] = .object(label)
        root["question"] = .object(payCost)
        return .object(root)
    }
}

/// Loaders for the schema 0.1.57 drift fixtures and their legacy counterparts.
enum Schema157Fixtures {
    enum Failure: Error {
        case shape
        case missingRepresentative(String)
    }

    static func data(_ name: String) throws -> Data {
        try load(name, subdirectory: "Fixtures/Schema157Drift")
    }

    static func value(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(data(name))
    }

    static func legacyValue(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(
            load("\(name)-pre-0.1.57", subdirectory: "Fixtures/LegacyContract")
        )
    }

    static func contractData(_ name: String) throws -> Data {
        try load(name, subdirectory: "Fixtures/Contract")
    }

    static func representative(named name: String) throws -> JSONValue {
        guard case let .object(root) = try value("question-presentation-representatives"),
              case let .array(entries)? = root["presentations"]
        else { throw Failure.shape }
        for case let .object(entry) in entries where entry["name"] == .string(name) {
            if let presentation = entry["presentation"] {
                return presentation
            }
        }
        throw Failure.missingRepresentative(name)
    }

    static func prompt(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation,
        binding: BoundQuestionPresentation
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: presentation.questionVersion,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            cardCatalog: nil,
            choiceLabelResolutions: [:],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func load(_ name: String, subdirectory: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: subdirectory
        ))
        return try Data(contentsOf: url)
    }
}
