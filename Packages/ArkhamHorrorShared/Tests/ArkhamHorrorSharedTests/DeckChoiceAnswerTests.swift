@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Deck choice answers")
struct DeckChoiceAnswerTests {
    private func loadFixture(_ name: String) throws -> Data {
        if let bundled = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveDreamEatersPlaythrough"
        ) {
            return try Data(contentsOf: bundled)
        }
        switch name {
        case "answer-deck":
            return Data(
                """
                {"tag":"DeckAnswer","deckId":"00000000-0000-0000-0000-000000000002",
                "playerId":"00000000-0000-0000-0000-000000000001"}
                """.utf8
            )
        case "answer-deck-list":
            return Data(
                """
                {"tag":"DeckListAnswer","deckList":{"slots":{},"sideSlots":{},
                "investigator_code":"c01001","investigator_name":"Contract investigator",
                "meta":null,"taboo_id":null,"url":null,"id":"fixture-deck",
                "name":"Contract deck"},"playerId":"00000000-0000-0000-0000-000000000001"}
                """.utf8
            )
        default:
            throw TestFailure()
        }
    }

    @Test("DeckAnswer encodes to the governed answer-deck fixture shape")
    func deckAnswerEncoding() throws {
        let answer = try DeckAnswer(
            deckId: DeckID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))),
            playerId: PlayerID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        )
        let encoded = try ContractJSON.encode(answer)
        let fixture = try loadFixture("answer-deck")
        #expect(
            try ContractJSON.decode(JSONValue.self, from: encoded)
                == ContractJSON.decode(JSONValue.self, from: fixture)
        )
    }

    @Test("DeckListAnswer encodes to the governed answer-deck-list fixture shape")
    func deckListAnswerEncoding() throws {
        let fixture = try loadFixture("answer-deck-list")
        let answer = try ContractJSON.decode(DeckListAnswer.self, from: fixture)
        let encoded = try ContractJSON.encode(answer)
        #expect(try ContractJSON.decode(DeckListAnswer.self, from: encoded) == answer)
        #expect(answer.playerId.rawValue.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(answer.deckList.name == "Contract deck")
    }

    @Test("Live ChooseDeck recognition accepts exact nullary and labeled deck prompts")
    func liveChooseDeckRecognitionAcceptsLabeledDeckPrompts() throws {
        let dreamEatersRaw = try ContractJSON.decode(
            JSONValue.self,
            from: loadFixture("question-dream-eaters-part-a-choose-deck")
        )

        #expect(LiveChooseDeckQuestion.matches(.object(["tag": .string("ChooseDeck")])))
        #expect(LiveChooseDeckQuestion.matches(dreamEatersRaw))
        #expect(!LiveChooseDeckQuestion.matches(.object([
            "tag": .string("ChooseDeck"),
            "extra": .null,
        ])))
        #expect(!LiveChooseDeckQuestion.matches(.object([
            "question": .object([
                "tag": .string("ChooseDeck"),
                "extra": .null,
            ]),
            "tag": .string("QuestionLabel"),
        ])))
        #expect(!LiveChooseDeckQuestion.matches(.object(["tag": .string("ChooseJoinDeck")])))
    }

    @Test("Captured Dream-Eaters labeled ChooseDeck bytes bind to the deck presentation")
    func dreamEatersQuestionLabelChooseDeckFixtureBinds() throws {
        let rawBytes = try loadFixture("question-dream-eaters-part-a-choose-deck")
        let presentationBytes = try loadFixture(
            "question-presentation-dream-eaters-part-a-choose-deck"
        )
        let raw = try ContractJSON.decode(JSONValue.self, from: rawBytes)
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: presentationBytes
        )
        let binding = try presentation.bind(to: raw, expectedQuestionVersion: 10)

        #expect(LiveChooseDeckQuestion.matches(raw))
        #expect(binding.presentation.questionKind == .chooseDeck)
        #expect(binding.presentation.answer == .deck(tags: ["DeckAnswer"]))
        #expect(binding.rawChoices.isEmpty)
    }
}
