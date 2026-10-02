// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Production-fixture-driven coverage for the `Read`/`BasicReadChoices` story-continue
/// prompt and the `ChooseOne`/`TargetLabel(LocationTarget)` starting-location prompt (issue
/// djensenius/ArkhamHorror-Apple#35), first governed at backend commit `52c7ee3b` and
/// extended with production `HeaderEntry` support at `d3e4c993`, schema `0.1.27`.
@Suite("Read story and location choice contract")
// swiftlint:disable:next type_body_length
struct ReadStoryQuestionTests {
    func fixture(_ name: String) throws -> Data {
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

    @Test(
        "HeaderEntry accepts any server integer heading level and preserves its catalog key",
        arguments: [
            (1, FlavorTextHeadingLevel.level1),
            (2, FlavorTextHeadingLevel(rawValue: 2)),
            (3, FlavorTextHeadingLevel.level3),
        ]
    )
    func headerEntryDecodes(level: Int, expected: FlavorTextHeadingLevel) throws {
        let bytes = Data(
            """
            {"tag":"Read","flavorText":{"title":null,"body":[\
            {"tag":"HeaderEntry","level":\(level),"key":"story.heading"}]},\
            "readChoices":{"tag":"BasicReadChoices","contents":[\
            {"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}
            """.utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let story = try #require(payload.supportedQuestion?.story)
        #expect(story.flavorText.body == [.header(level: expected, key: "story.heading")])
    }

    // swiftlint:disable line_length
    @Test("Every Arkham.Text FlavorTextEntry constructor decodes from server JSON")
    func allServerFlavorTextEntryConstructorsDecode() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(Self.allFlavorEntriesReadQuestion.utf8)
        )
        let story = try #require(payload.supportedQuestion?.story)
        #expect(story.flavorText.title == "$story.title")
        #expect(story.flavorText.body == Self.expectedAllFlavorEntries)
        #expect(payload.isUpdateRequired == false)
    }

    @Test("Every FlavorTextEntry constructor resolves without a catalog using server-provided fallback text")
    func allServerFlavorTextEntryConstructorsResolveWithoutCatalog() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(Self.allFlavorEntriesReadQuestion.utf8)
        )
        let flavorText = try #require(payload.supportedQuestion?.story?.flavorText)
        #expect(StoryNarrativeLocalization.resolve(
            flavorText,
            resolver: nil,
            catalogUnavailability: .catalog(.notAdvertised)
        ) == .resolved(ResolvedStory(
            title: "story.title",
            body: Self.expectedAllFlavorEntriesWithoutCatalog
        )))
    }

    @Test("Every FlavorTextEntry constructor resolves with a catalog where keys are available")
    func allServerFlavorTextEntryConstructorsResolveWithCatalog() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.basic", "story.heading", "story.i18n", "story.listItem", "story.title"],
            chunkEntries: """
            {"story.title":{"form":"message","nodes":[{"type":"text","value":"Catalog title"}],"variables":[]},\
            "story.basic":{"form":"message","nodes":[{"type":"text","value":"Catalog basic"}],"variables":[]},\
            "story.heading":{"form":"message","nodes":[{"type":"text","value":"Catalog heading"}],"variables":[]},\
            "story.i18n":{"form":"message","nodes":[{"type":"text","value":"Catalog i18n"}],"variables":[]},\
            "story.listItem":{"form":"message","nodes":[{"type":"text","value":"Catalog list item"}],"variables":[]}}
            """
        )
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(Self.allFlavorEntriesReadQuestion.utf8)
        )
        let flavorText = try #require(payload.supportedQuestion?.story?.flavorText)
        #expect(StoryNarrativeLocalization.resolve(
            flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        ) == .resolved(ResolvedStory(
            title: "Catalog title",
            body: Self.expectedAllFlavorEntriesWithCatalog
        )))
    }

    @Test("A missing catalog key falls back to readable server data and leaves Continue answerable")
    func missingCatalogKeyFallbackStaysAnswerable() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let bytes = Data(
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"I18nEntry","key":"story.missing","variables":{"name":"Daisy"}}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#.utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let question = try #require(payload.supportedQuestion)
        let story = try #require(question.story)
        let resolution = StoryNarrativeLocalization.resolve(
            story.flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        )
        #expect(resolution == .resolved(ResolvedStory(
            title: nil,
            body: [.text("story.missing (name: Daisy)")]
        )))
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        #expect(projection.isChoiceActionable(question.choices[0], storyResolution: resolution))
    }

    static var allFlavorEntriesReadQuestion: String {
        #"{"tag":"Read","flavorText":{"title":"$story.title","body":[{"tag":"BasicEntry","text":"$story.basic"},{"tag":"HeaderEntry","level":2,"key":"story.heading"},{"tag":"I18nEntry","key":"story.i18n","variables":{"name":"Daisy"}},{"tag":"ModifyEntry","modifiers":["BlueEntry","GreenEntry","BorderedEntry","RedEntry","RightAligned","PlainText","InvalidEntry","ValidEntry","CenteredEntry","ResolutionEntry","CheckpointEntry","InterludeEntry","NestedEntry","NoUnderline","CodexEntry","HauntedEntry","TokenRevealEntry","ByDifficultyEntry"],"entry":{"tag":"BasicEntry","text":"Modified"}},{"tag":"CompositeEntry","entries":[{"tag":"BasicEntry","text":"Composite A"},{"tag":"BasicEntry","text":"Composite B"}]},{"tag":"ColumnEntry","entries":[{"tag":"BasicEntry","text":"Column A"},{"tag":"BasicEntry","text":"Column B"}]},{"tag":"ListEntry","list":[{"entry":{"tag":"I18nEntry","key":"story.listItem","variables":{}},"nested":[{"entry":{"tag":"BasicEntry","text":"Nested basic"},"nested":[]}]}]},{"tag":"CardEntry","cardCode":"c01159","imageModifiers":["RemoveImage","SelectImage","SmallImage"]},{"tag":"TarotEntry","tarot":"TheFool0"},{"tag":"ChaosTokenEntry","chaosTokenFace":"Skull"},{"tag":"ChaosTokenMorphEntry","morphFrom":"Skull","morphTo":"Cultist"},{"tag":"EntrySplit"}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#
    }

    static var allModifiers: [FlavorTextModifier] {
        [
            .blueEntry, .greenEntry, .borderedEntry, .redEntry, .rightAligned, .plainText,
            .invalidEntry, .validEntry, .centeredEntry, .resolutionEntry, .checkpointEntry,
            .interludeEntry, .nestedEntry, .noUnderline, .codexEntry, .hauntedEntry,
            .tokenRevealEntry, .byDifficultyEntry,
        ]
    }

    static var expectedAllFlavorEntries: [FlavorTextEntry] {
        [
            .basic(text: "$story.basic"),
            .header(level: FlavorTextHeadingLevel(rawValue: 2), key: "story.heading"),
            .i18n(key: "story.i18n", variables: .object(["name": .string("Daisy")])),
            .modify(modifiers: allModifiers, entry: .basic(text: "Modified")),
            .composite(entries: [.basic(text: "Composite A"), .basic(text: "Composite B")]),
            .column(entries: [.basic(text: "Column A"), .basic(text: "Column B")]),
            .list(items: [
                FlavorTextListItem(
                    entry: .i18n(key: "story.listItem", variables: .object([:])),
                    nested: [FlavorTextListItem(entry: .basic(text: "Nested basic"), nested: [])]
                ),
            ]),
            .card(
                cardCode: BoardTestFixtures.cardCode("c01159"),
                imageModifiers: [.removeImage, .selectImage, .smallImage]
            ),
            .tarot(arcana: "TheFool0"),
            .chaosToken(face: .skull),
            .chaosTokenMorph(from: .skull, target: .cultist),
            .split,
        ]
    }

    static var expectedAllFlavorEntriesWithoutCatalog: [ResolvedStoryEntry] {
        expectedResolvedEntries(
            basic: .text("story.basic"),
            heading: "story.heading",
            i18n: .text("story.i18n (name: Daisy)"),
            listItem: .text("story.listItem")
        )
    }

    static var expectedAllFlavorEntriesWithCatalog: [ResolvedStoryEntry] {
        expectedResolvedEntries(
            basic: .nodes([.text("Catalog basic")]),
            heading: "Catalog heading",
            i18n: .nodes([.text("Catalog i18n")]),
            listItem: .nodes([.text("Catalog list item")])
        )
    }

    static func expectedResolvedEntries(
        basic: ResolvedStoryEntry,
        heading: String,
        i18n: ResolvedStoryEntry,
        listItem: ResolvedStoryEntry
    ) -> [ResolvedStoryEntry] {
        [
            basic,
            .heading(level: FlavorTextHeadingLevel(rawValue: 2), nodes: [.text(heading)]),
            i18n,
            .modified(modifiers: allModifiers, entry: .text("Modified")),
            .composite(entries: [.text("Composite A"), .text("Composite B")]),
            .columns(entries: [.text("Column A"), .text("Column B")]),
            .list(items: [
                ResolvedStoryListItem(
                    entry: listItem,
                    nested: [ResolvedStoryListItem(entry: .text("Nested basic"), nested: [])]
                ),
            ]),
            .cardReference(
                cardCode: BoardTestFixtures.cardCode("c01159"),
                imageModifiers: [.removeImage, .selectImage, .smallImage]
            ),
            .tarotReference(arcana: "TheFool0"),
            .chaosTokenReference(face: .skull),
            .chaosTokenMorph(from: .skull, target: .cultist),
            .divider,
        ]
    }

    // swiftlint:enable line_length

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

    func expectedLocationID(_ uuid: String) -> LocationID {
        // swiftlint:disable:next force_unwrapping
        LocationID(UUID(uuidString: uuid)!)
    }

    // MARK: - Malformed Read questions remain explicit unsupported, never a silent Continue

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
            // HeaderEntry missing its governed level/key fields.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"HeaderEntry","text":"x"}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // HeaderEntry level must be a JSON integer.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"HeaderEntry","level":"1","key":"story.heading"}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // HeaderEntry is closed against additional fields.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"HeaderEntry","level":1,"key":"story.heading","extra":true}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
            // I18nEntry missing required "variables" key.
            #"{"tag":"Read","flavorText":{"title":null,"body":[{"tag":"I18nEntry","key":"x"}]},"readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}"#,
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
        "choiceDisplayTitle falls back to a concise, non-UUID-leaking placeholder when the projection doesn't yet carry that location"
    )
    func choiceDisplayTitleFallsBackWhenLocationMissing() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        let title = BoardDisplayFormatting.choiceDisplayTitle(for: choice, in: projection)
        #expect(title == "Unavailable location (choice 1)")
        #expect(!title.contains("d5a66e84"))
    }

    // swiftlint:enable line_length

    @Test("choiceDisplayTitle uses the static per-kind title for every non-location choice")
    func choiceDisplayTitleUsesStaticTitleForOtherKinds() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(
            BoardDisplayFormatting.choiceDisplayTitle(for: choice, in: projection) == "Continue"
        )
    }
}
