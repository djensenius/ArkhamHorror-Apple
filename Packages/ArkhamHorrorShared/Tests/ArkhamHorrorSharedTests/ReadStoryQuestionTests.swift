@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Production-fixture-driven coverage for the `Read`/`BasicReadChoices` story-continue
/// prompt and the `ChooseOne`/`TargetLabel(LocationTarget)` starting-location prompt (issue
/// djensenius/ArkhamHorror-Apple#35), pinned to backend commit `52c7ee3b`, schema `0.1.22`.
@Suite("Read story and location choice contract")
struct ReadStoryQuestionTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    // MARK: - question-read.json

    @Test("question-read.json decodes the full setup ListEntry/I18nEntry story tree")
    func readFixtureDecodesStoryTree() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read")
        )
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .read)

        // The single governed continue choice is synthesized at index 0 so it flows
        // through the exact same choice-index submission path as every other question.
        #expect(question.choices.map(\.index) == [0])
        #expect(question.choices.map(\.title) == ["Continue"])
        #expect(question.choices.map(\.isSupported) == [true])
        guard case let .continueReading(messages) = question.choices[0].content else {
            Issue.record("Expected .continueReading")
            return
        }
        #expect(messages.isEmpty)

        let story = try #require(question.story)
        #expect(story.readCards == nil)
        #expect(story.flavorText.title == "$setup")
        #expect(story.flavorText.body.count == 1)
        guard case let .list(items) = story.flavorText.body[0] else {
            Issue.record("Expected a single top-level ListEntry")
            return
        }
        #expect(items.count == 4)
        let expectedKeys = [
            "nightOfTheZealot.theGathering.setup.gatherSets",
            "nightOfTheZealot.theGathering.setup.placeLocations",
            "nightOfTheZealot.theGathering.setup.setOutOfPlay",
            "shuffleRemainder",
        ]
        for (item, expectedKey) in zip(items, expectedKeys) {
            guard case let .i18n(key, variables) = item.entry else {
                Issue.record("Expected an I18nEntry list item")
                return
            }
            #expect(key == expectedKey)
            #expect(variables == .object([:]))
            #expect(item.nested.isEmpty)
        }
    }

    @Test("question-read-with-cards.json decodes a BasicEntry body and non-null readCards")
    func readWithCardsFixtureDecodes() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read-with-cards")
        )
        let question = try #require(payload.supportedQuestion)
        let story = try #require(question.story)
        #expect(story.flavorText.title == nil)
        #expect(story.flavorText.body == [.basic(text: "Contract fixture flavor text.")])
        #expect(story.readCards == [BoardTestFixtures.cardCode("c01159")])
    }

    // MARK: - question-choose-one-location.json / -multiple.json

    @Test("question-choose-one-location.json decodes the real Study TargetLabel choice")
    func singleLocationFixtureDecodes() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .chooseOne)
        #expect(question.story == nil)
        #expect(question.choices.count == 1)
        let choice = question.choices[0]
        #expect(choice.index == 0)
        #expect(choice.isSupported)
        #expect(choice.title == "Choose starting location")
        guard case let .chooseLocation(locationID, messages) = choice.content else {
            Issue.record("Expected .chooseLocation")
            return
        }
        #expect(locationID == expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025"))
        #expect(messages.count == 2)
    }

    @Test(
        // swiftlint:disable:next line_length
        "question-choose-one-location-multiple.json preserves original backend order and Answer.choice index mapping across all three real locations"
    )
    func multiLocationFixturePreservesOrder() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixture("question-choose-one-location-multiple")
        )
        let question = try #require(payload.supportedQuestion)
        #expect(question.choices.map(\.index) == [0, 1, 2])
        let expectedSuffixes = ["000000000398", "000000000399", "00000000039a"]
        for (choice, suffix) in zip(question.choices, expectedSuffixes) {
            #expect(choice.isSupported)
            #expect(choice.locationID == BoardTestFixtures.locationID(suffix))
        }
        // Selecting the middle (second) location sends choice index 1 -- the exact
        // zero-based array position, never a re-sorted or filtered position.
        let answer = BasicChoiceAnswer(
            choice: 1, playerID: BoardTestFixtures.playerID(), questionVersion: 0
        )
        let encoded = try ContractJSON.encode(answer)
        let encodedText = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(encodedText.contains(#""choice":1"#))
    }

    private func expectedLocationID(_ uuid: String) -> LocationID {
        // swiftlint:disable:next force_unwrapping
        LocationID(UUID(uuidString: uuid)!)
    }

    // MARK: - Malformed Read questions remain explicit unsupported, never a silent Continue

    // Governed malformed JSON remains legible as exact one-line token streams.
    // swiftlint:disable line_length
    @Test(
        "Malformed Read questions become update-required, never a normalized continue",
        arguments: [
            // Unknown top-level alias instead of the governed "Read" tag.
            #"{"tag":"ReadWithHeader","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // Non-governed ReadChoices variant.
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoicesN","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // readCards omitted entirely (must always be present, even as null).
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]}}"#,
            // readCards present but neither null nor an array.
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":42}"#,
            // readCards array containing an invalid card code.
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":["NOTVALID"]}"#,
            // Continue label's messages must stay exactly empty.
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[{"tag":"SomeMessage"}]}]},"readCards":null}"#,
            // Continue label's label text must stay exactly "$continue".
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$otherLabel","messages":[]}]},"readCards":null}"#,
            // BasicReadChoices.contents must have exactly one element.
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[]},"readCards":null}"#,
            // flavorText missing its required "title" key.
            #"{"tag":"Read","flavorText":{"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // flavorTextEntry: unknown/unsupported constructor (real backend HeaderEntry).
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"HeaderEntry","text":"x"}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // I18nEntry missing required "variables" key.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"I18nEntry","key":"x"}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // I18nEntry key must be non-empty.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"I18nEntry","key":"","variables":{}}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // Nested ListEntry item with a malformed inner entry fails the whole question.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"ListEntry","list":[{"entry":{"tag":"BogusEntry"},"nested":[]}]}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // Unexpected additional top-level key.
            #"{"tag":"Read","flavorText":{"title":null,"body":[]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null,"extra":true}"#,
        ]
    )
    func malformedReadQuestionsFailClosed(json: String) throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(json.utf8)
        )
        #expect(payload.supportedQuestion == nil)
        #expect(payload.isUpdateRequired)
    }

    @Test(
        "Malformed/cross-variant TargetLabel choices remain visible and disabled, never filtered, reindexed, or silently accepted",
        arguments: [
            // Non-Location Target variant (e.g. EnemyTarget) remains unsupported here,
            // though it stays opaque wherever it appears inside PublicGame.
            #"{"tag":"TargetLabel","target":{"tag":"EnemyTarget","contents":"d5a66e84-c729-4066-8475-d8a155609025"},"messages":[]}"#,
            // Canonical UUID pattern rejects uppercase spelling.
            #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"D5A66E84-C729-4066-8475-D8A155609025"},"messages":[]}"#,
            // Closed shape rejects a cross-variant alias field.
            #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"d5a66e84-c729-4066-8475-d8a155609025"},"messages":[],"investigatorId":"c01001"}"#,
            // locationTarget itself is closed against extra keys.
            #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"d5a66e84-c729-4066-8475-d8a155609025","extra":1},"messages":[]}"#,
            // Non-UUID contents.
            #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"not-a-uuid"},"messages":[]}"#,
        ]
    )
    func malformedTargetLabelChoicesFailClosed(choiceJSON: String) throws {
        let bytes = Data(
            #"{"tag":"ChooseOne","choices":[\#(choiceJSON)]}"#.utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(choice.index == 0)
        #expect(!choice.isSupported)
        #expect(choice.title == "Update required")
    }

    @Test(
        "A mixed choices array keeps an unsupported TargetLabel visible and disabled alongside supported choices at their original indices, never filtered/reindexed"
    )
    func mixedSupportedAndUnsupportedChoicesPreserveIndices() throws {
        let bytes = Data(
            (
                #"{"tag":"ChooseOne","choices":["# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"d5a66e84-c729-4066-8475-d8a155609025"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"EnemyTarget","contents":"d5a66e84-c729-4066-8475-d8a155609025"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-000000000399"},"messages":[]}"# +
                    "]}"
            ).utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let question = try #require(payload.supportedQuestion)
        #expect(question.choices.map(\.index) == [0, 1, 2])
        #expect(question.choices.map(\.isSupported) == [true, false, true])
        #expect(question.choices[0].locationID
            == expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025"))
        #expect(question.choices[2].locationID == BoardTestFixtures.locationID("000000000399"))
    }

    // MARK: - choiceDisplayTitle view-state resolution (BoardDisplayFormatting)

    @Test("choiceDisplayTitle resolves a location choice against the authoritative projection")
    func choiceDisplayTitleResolvesKnownLocation() throws {
        let locationID = expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025")
        let snapshot = BoardTestFixtures.snapshot(
            locations: [
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, label: "Study"
                ))),
            ]
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(
            BoardDisplayFormatting.choiceDisplayTitle(for: choice, in: projection) == "Study"
        )
    }

    @Test(
        "choiceDisplayTitle falls back to a deterministic lowercase UUID when the projection doesn't yet carry that location"
    )
    func choiceDisplayTitleFallsBackWhenLocationMissing() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(
            BoardDisplayFormatting.choiceDisplayTitle(for: choice, in: projection)
                == "Location d5a66e84-c729-4066-8475-d8a155609025"
        )
    }

    @Test("choiceDisplayTitle uses the static per-kind title for every non-location choice")
    func choiceDisplayTitleUsesStaticTitleForOtherKinds() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(BoardDisplayFormatting.choiceDisplayTitle(for: choice, in: projection) == "Continue")
    }
    // swiftlint:enable line_length
}
