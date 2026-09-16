@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Semantic question presentation v1")
struct QuestionPresentationTests {
    @Test("Q34 decodes, binds source index 12, and round-trips")
    func gatheringActObjectiveBinds() throws {
        let presentation = try presentationFixture("question-presentation-gathering-act-objective")
        #expect(presentation.protocolVersion == 1)
        #expect(presentation.questionVersion == 34)
        #expect(presentation.questionKind == .playerWindowChooseOne)
        #expect(presentation.choiceCount == 13)
        #expect(presentation.choices.map(\.sourceIndex) == Array(0 ... 12))

        let objective = try #require(
            presentation.choices.first { $0.sourceIndex == 12 }
        )
        #expect(objective.kind == .advanceAct)
        #expect(objective.actorID == "c01001")
        #expect(objective.entity == .init(kind: .act, id: "c01108"))
        #expect(
            objective.ability
                == .init(
                    cardCode: "c01108",
                    index: 999,
                    type: .objective,
                    actions: [],
                    canBeCancelled: true
                )
        )
        #expect(objective.cost == .groupClue(amount: .perPlayer(2), scope: .anywhere))

        let binding = try presentation.bind(
            to: rawFixture("question-gathering-act-objective"),
            expectedQuestionVersion: 34
        )
        #expect(binding.rawChoices.count == 13)
        #expect(binding.descriptor(forSourceIndex: 12) == objective)
        #expect(binding.rawChoice(at: 12) != nil)
        #expect(binding.rawChoice(at: 13) == nil)

        let encoded = try ContractJSON.encode(presentation)
        #expect(try ContractJSON.decode(QuestionPresentation.self, from: encoded) == presentation)
    }

    @Test("Q35 uses the same advanceAct descriptor without local authority fields")
    func gatheringActAdvanceBinds() throws {
        let presentation = try presentationFixture("question-presentation-gathering-act-advance")
        let binding = try presentation.bind(
            to: rawFixture("question-gathering-act-advance"),
            expectedQuestionVersion: 35
        )
        #expect(presentation.questionKind == .chooseOne)
        #expect(presentation.choiceCount == 1)
        #expect(
            binding.descriptor(forSourceIndex: 0)
                == .init(
                    sourceIndex: 0,
                    kind: .advanceAct,
                    actorID: nil,
                    entity: .init(kind: .act, id: "c01108"),
                    label: nil,
                    ability: nil,
                    cost: nil
                )
        )
    }

    // swiftlint:disable line_length
    @Test(
        "Closed presentation shapes reject malformed or unknown values",
        arguments: [
            #"{"protocolVersion":2,"questionVersion":1,"questionKind":"chooseOne","choiceCount":0,"choices":[]}"#,
            #"{"protocolVersion":1,"questionVersion":-1,"questionKind":"chooseOne","choiceCount":0,"choices":[]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"future","choiceCount":0,"choices":[]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":0,"choices":[],"extra":true}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"gainResource"}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"localizedLabel"}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"advanceAct","entity":{"kind":"agenda","id":"a"}}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"advanceAct","entity":{"kind":"act","id":"a"},"actorId":"i"}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"useAbility","actorId":"i","ability":{"cardCode":"c","index":1,"type":"action","actions":["fight","fight"],"canBeCancelled":true},"cost":{"kind":"free"}}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"useAbility","actorId":"i","ability":{"cardCode":"c","index":1,"type":"action","actions":[],"canBeCancelled":true},"cost":{"kind":"all","costs":[]}}]}"#,
            #"{"protocolVersion":1,"questionVersion":38,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"assignDamage","actorId":"c01001","entity":{"kind":"investigator","id":"c01001"}}]}"#,
            #"{"protocolVersion":1,"questionVersion":38,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"assignHorror","entity":{"kind":"location","id":"dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"}}]}"#,
            #"{"protocolVersion":1,"questionVersion":36,"questionKind":"playerWindowChooseOne","choiceCount":12,"choices":[{"sourceIndex":9,"kind":"move","actorId":"c01001","entity":{"kind":"location","id":"a3497b9f-796b-406d-aeb4-9b96fa9f4905"},"ability":{"cardCode":"c01114","index":104,"type":"action","actions":["move"],"canBeCancelled":true}}]}"#,
            #"{"protocolVersion":1,"questionVersion":37,"questionKind":"windowChooseOne","choiceCount":1,"choices":[{"sourceIndex":0,"kind":"resolveForcedAbility","actorId":"c01001","ability":{"cardCode":"c01114","index":1,"type":"forced","actions":[],"canBeCancelled":true},"cost":{"kind":"free"}}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":1,"choices":[{"sourceIndex":1,"kind":"applySkillTestResults"}]}"#,
            #"{"protocolVersion":1,"questionVersion":1,"questionKind":"chooseOne","choiceCount":2,"choices":[{"sourceIndex":0,"kind":"applySkillTestResults"},{"sourceIndex":0,"kind":"applySkillTestResults"}]}"#,
        ]
    )
    // swiftlint:enable line_length
    func malformedPresentationFailsClosed(json: String) {
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(QuestionPresentation.self, from: Data(json.utf8))
        }
    }

    // swiftlint:disable line_length
    @Test(
        "Raw derivation mirrors supported constructors, wrappers, Read variants, and unsupported",
        arguments: [
            (#"{"tag":"ChooseN","amount":2,"choices":[{},{}]}"#, QuestionPresentation.Kind.chooseN, 2),
            (#"{"tag":"QuestionLabel","label":"x","card":null,"question":{"tag":"ChooseSome1","label":"pick","choices":[{}]}}"#, .chooseSome, 1),
            (#"{"tag":"PayCostQuestion","cost":{"tag":"Free"},"question":{"tag":"ChooseUpToN","amount":1,"choices":[{}]}}"#, .chooseUpToN, 1),
            (#"{"tag":"QuestionWithSource","source":{},"tooltip":null,"question":{"tag":"WindowChooseOne","choices":[{},{}]}}"#, .windowChooseOne, 2),
            (#"{"tag":"Read","flavorText":{},"readChoices":{"tag":"BasicReadChoices","contents":[{}]},"readCards":null}"#, .read, 1),
            (#"{"tag":"Read","flavorText":{},"readChoices":{"tag":"BasicReadChoicesN","contents":[2,[{},{}]]},"readCards":null}"#, .read, 2),
            (#"{"tag":"Read","flavorText":{},"readChoices":{"tag":"BasicReadChoicesUpToN","contents":[1,[{}]]},"readCards":null}"#, .read, 1),
            (#"{"tag":"Read","flavorText":{},"readChoices":{"tag":"LeadInvestigatorMustDecide","contents":[{},{}]},"readCards":null}"#, .read, 2),
            (#"{"tag":"ChooseOneAtATimeWithAuto","label":"all","choices":[{}]}"#, .unsupported, 0),
            (#"{"tag":"ChooseAmounts","choices":[{},{}]}"#, .unsupported, 0),
        ]
    )
    // swiftlint:enable line_length
    func derivesRawShape(
        rawJSON: String,
        expectedKind: QuestionPresentation.Kind,
        expectedCount: Int
    ) throws {
        let presentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 7,
            questionKind: expectedKind,
            choiceCount: expectedCount,
            choices: []
        )
        let binding = try presentation.bind(
            to: ContractJSON.decode(JSONValue.self, from: Data(rawJSON.utf8)),
            expectedQuestionVersion: 7
        )
        #expect(binding.rawChoices.count == expectedCount)
    }

    // swiftlint:disable line_length
    @Test(
        "Raw derivation rejects negative counted question amounts",
        arguments: [
            #"{"tag":"ChooseN","amount":-1,"choices":[{}]}"#,
            #"{"tag":"ChooseUpToN","amount":-1,"choices":[{}]}"#,
            #"{"tag":"Read","flavorText":{},"readChoices":{"tag":"BasicReadChoicesN","contents":[-1,[{}]]},"readCards":null}"#,
            #"{"tag":"Read","flavorText":{},"readChoices":{"tag":"BasicReadChoicesUpToN","contents":[-1,[{}]]},"readCards":null}"#,
        ]
    )
    // swiftlint:enable line_length
    func negativeRawCountFailsClosed(rawJSON: String) {
        let presentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 7,
            questionKind: .chooseN,
            choiceCount: 1,
            choices: []
        )
        #expect(throws: QuestionPresentationBindingError.self) {
            try presentation.bind(
                to: ContractJSON.decode(JSONValue.self, from: Data(rawJSON.utf8)),
                expectedQuestionVersion: 7
            )
        }
    }

    @Test("Binding rejects version, kind, count, and malformed known raw questions")
    func bindingMismatchesFailClosed() throws {
        let raw = try rawFixture("question-gathering-act-advance")
        let presentation = try presentationFixture("question-presentation-gathering-act-advance")

        #expect(throws: QuestionPresentationBindingError.self) {
            try presentation.bind(to: raw, expectedQuestionVersion: 34)
        }
        #expect(throws: QuestionPresentationBindingError.self) {
            try QuestionPresentation(
                protocolVersion: 1,
                questionVersion: 35,
                questionKind: .read,
                choiceCount: 1,
                choices: []
            ).bind(to: raw, expectedQuestionVersion: 35)
        }
        #expect(throws: QuestionPresentationBindingError.self) {
            try QuestionPresentation(
                protocolVersion: 1,
                questionVersion: 35,
                questionKind: .chooseOne,
                choiceCount: 2,
                choices: []
            ).bind(to: raw, expectedQuestionVersion: 35)
        }
        #expect(throws: QuestionPresentationBindingError.self) {
            try presentation.bind(
                to: ContractJSON.decode(
                    JSONValue.self,
                    from: Data(#"{"tag":"ChooseOne","choices":"not-an-array"}"#.utf8)
                ),
                expectedQuestionVersion: 35
            )
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
