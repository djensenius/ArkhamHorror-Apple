@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Production-fixture-driven and synthetic-vocabulary coverage for
/// ``StoryNarrativeLocalization``, this client's entire lawful, fail-closed narrative
/// localization boundary (issue djensenius/ArkhamHorror-Apple#35, independent-review
/// blocker 2). Proves the real, currently-vendored `question-read.json` can fall back to
/// server-provided keys when catalog text is unavailable, that the substitution/`$`-prefix
/// (for both `title` and `BasicEntry.text`)/recursive-`ListEntry` mechanisms are each
/// independently correct against an injected synthetic vocabulary (never real,
/// copyrighted narrative content), and that malformed variable substitution still fails
/// closed rather than partially substituting or guessing. `BasicEntry.text`'s own
/// `$`-prefix coverage lives in the
/// sibling `StoryNarrativeLocalizationBasicEntryTests.swift` extension.
@Suite("Story narrative localization boundary")
struct StoryNarrativeLocalizationTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    private func readStory(from fixtureName: String) throws -> FlavorText {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture(fixtureName)
        )
        let question = try #require(payload.supportedQuestion)
        return try #require(question.story).flavorText
    }

    // MARK: - Real production fixtures

    @Test(
        "question-read.json falls back to server keys when dotted i18n keys are missing"
    )
    func realReadFixtureFallsBackToServerKeys() throws {
        let flavorText = try readStory(from: "question-read")
        #expect(flavorText.title == "$setup")
        let resolved = try #require(StoryNarrativeLocalization.resolvedStory(for: flavorText))
        #expect(resolved.title == "Setup")
        guard case let .list(items)? = resolved.body.first else {
            Issue.record("Expected the setup story to remain a list")
            return
        }
        #expect(items.map(\.entry) == [
            .text("nightOfTheZealot.theGathering.setup.gatherSets"),
            .text("nightOfTheZealot.theGathering.setup.placeLocations"),
            .text("nightOfTheZealot.theGathering.setup.setOutOfPlay"),
            .text("shuffleRemainder"),
        ])
    }

    @Test("The real question-read-with-cards.json BasicEntry-only story resolves lawfully")
    func realReadWithCardsFixtureResolves() throws {
        let flavorText = try readStory(from: "question-read-with-cards")
        let resolved = try #require(StoryNarrativeLocalization.resolvedStory(for: flavorText))
        #expect(resolved.title == nil)
        #expect(resolved.body == [.text("Contract fixture flavor text.")])
    }

    // MARK: - `$`-prefix vs literal title

    @Test("A $-prefixed title resolves via the vocabulary; a nil title stays nil")
    func dollarPrefixedTitleResolvesViaVocabulary() {
        let withTitle = FlavorText(title: "$continue", body: [])
        let resolved = StoryNarrativeLocalization.resolvedStory(for: withTitle)
        #expect(resolved?.title == "Continue")

        let noTitle = FlavorText(title: nil, body: [])
        #expect(StoryNarrativeLocalization.resolvedStory(for: noTitle)?.title == nil)
    }

    @Test("A title without a leading $ passes through completely literally, never looked up")
    func literalTitlePassesThroughVerbatim() {
        let flavorText = FlavorText(title: "Not an i18n key", body: [])
        let resolved = StoryNarrativeLocalization.resolvedStory(for: flavorText)
        #expect(resolved?.title == "Not an i18n key")
    }

    @Test("An unresolvable $-prefixed title falls back to the key")
    func unresolvableDollarPrefixedTitleFallsBack() {
        let flavorText = FlavorText(title: "$unknownVocabularyKey", body: [])
        #expect(
            StoryNarrativeLocalization.resolvedStory(for: flavorText)?.title
                == "unknownVocabularyKey"
        )
    }

    // MARK: - BasicEntry `$`-prefix semantics

    // See `StoryNarrativeLocalizationBasicEntryTests.swift` (split out to stay under the
    // `type_body_length` limit).

    // MARK: - I18nEntry resolution and variable substitution (synthetic vocabulary only)

    @Test("An I18nEntry key resolves via an injected vocabulary with no variables")
    func i18nEntryResolvesWithoutVariables() {
        let vocabulary = ["greeting": "Hello there"]
        let flavorText = FlavorText(
            title: nil, body: [.i18n(key: "greeting", variables: .object([:]))]
        )
        let resolved = StoryNarrativeLocalization.resolvedStory(
            for: flavorText, vocabulary: vocabulary
        )
        #expect(resolved?.body == [.text("Hello there")])
    }

    @Test("An I18nEntry key missing from the vocabulary falls back to the key")
    func i18nEntryMissingFromVocabularyFallsBack() {
        let flavorText = FlavorText(
            title: nil, body: [.i18n(key: "notInVocabulary", variables: .object([:]))]
        )
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText)?.body == [
            .text("notInVocabulary"),
        ])
    }

    @Test("A named {variable} placeholder substitutes from a string variable value")
    func namedPlaceholderSubstitutesStringVariable() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "Hello {name}!", variables: .object(["name": .string("Roland")])
        )
        #expect(result == "Hello Roland!")
    }

    @Test("A named {variable} placeholder substitutes from a number variable value")
    func namedPlaceholderSubstitutesNumberVariable() throws {
        let count = try JSONValue.number(JSONNumber(exactDecimalLiteral: "3"))
        let result = StoryNarrativeLocalization.substituteVariables(
            "Draw {count} cards", variables: .object(["count": count])
        )
        #expect(result == "Draw 3 cards")
    }

    @Test("Multiple placeholders and surrounding literal text all substitute correctly")
    func multiplePlaceholdersSubstituteInOrder() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "{greeting}, {name}!",
            variables: .object(["greeting": .string("Hello"), "name": .string("Roland")])
        )
        #expect(result == "Hello, Roland!")
    }

    @Test("A missing variable identifier fails closed")
    func missingVariableFailsClosed() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "Hello {name}!", variables: .object([:])
        )
        #expect(result == nil)
    }

    @Test("An unterminated { placeholder with no matching } fails closed")
    func unterminatedPlaceholderFailsClosed() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "Hello {name!", variables: .object(["name": .string("Roland")])
        )
        #expect(result == nil)
    }

    @Test("An invalid placeholder identifier (leading digit) fails closed")
    func invalidPlaceholderIdentifierFailsClosed() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "Count: {1name}", variables: .object(["1name": .string("x")])
        )
        #expect(result == nil)
    }

    @Test("variables that isn't a JSON object fails closed even with no placeholders")
    func nonObjectVariablesFailsClosed() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "Hello {name}!", variables: .array([])
        )
        #expect(result == nil)
    }

    @Test(
        "Every unsupported JSONValue variable type (null, bool, array, object) fails closed"
    )
    func unsupportedVariableTypesFailClosed() {
        let unsupportedValues: [JSONValue] = [.null, .bool(true), .array([]), .object([:])]
        for value in unsupportedValues {
            let result = StoryNarrativeLocalization.substituteVariables(
                "Value: {value}", variables: .object(["value": value])
            )
            #expect(result == nil, "expected \(value.kindDescription) to fail closed")
        }
    }

    @Test("A stray unmatched } with no preceding { passes through literally")
    func strayUnmatchedClosingBracePassesThroughLiterally() {
        let result = StoryNarrativeLocalization.substituteVariables(
            "Cost: 3}", variables: .object([:])
        )
        #expect(result == "Cost: 3}")
    }

    // MARK: - Recursive ListEntry resolution

    @Test("A recursive ListEntry with every nested item resolvable resolves completely")
    func recursiveListEntryResolvesWhenEveryItemResolves() throws {
        let vocabulary = ["continue": "Continue", "setup": "Setup"]
        let flavorText = FlavorText(
            title: nil,
            body: [
                .list(items: [
                    FlavorTextListItem(
                        entry: .i18n(key: "setup", variables: .object([:])),
                        nested: [
                            FlavorTextListItem(
                                entry: .basic(text: "Nested literal"), nested: []
                            ),
                        ]
                    ),
                    FlavorTextListItem(
                        entry: .i18n(key: "continue", variables: .object([:])), nested: []
                    ),
                ]),
            ]
        )
        let resolved = try #require(
            StoryNarrativeLocalization.resolvedStory(for: flavorText, vocabulary: vocabulary)
        )
        let expected = ResolvedStory(
            title: nil,
            body: [
                .list(items: [
                    ResolvedStoryListItem(
                        entry: .text("Setup"),
                        nested: [ResolvedStoryListItem(entry: .text("Nested literal"), nested: [])]
                    ),
                    ResolvedStoryListItem(entry: .text("Continue"), nested: []),
                ]),
            ]
        )
        #expect(resolved == expected)
    }

    @Test(
        "A single unresolvable entry nested deep inside a ListEntry falls back in place"
    )
    func recursiveListEntryPartialFailureFallsBackInPlace() {
        let vocabulary = ["continue": "Continue"]
        let flavorText = FlavorText(
            title: nil,
            body: [
                .list(items: [
                    FlavorTextListItem(
                        entry: .i18n(key: "continue", variables: .object([:])),
                        nested: [
                            FlavorTextListItem(
                                // Deeply nested, unresolvable against this vocabulary.
                                entry: .i18n(key: "unresolvable.key", variables: .object([:])),
                                nested: []
                            ),
                        ]
                    ),
                ]),
            ]
        )
        #expect(
            StoryNarrativeLocalization.resolvedStory(for: flavorText, vocabulary: vocabulary)?.body
                == [
                    .list(items: [
                        ResolvedStoryListItem(
                            entry: .text("Continue"),
                            nested: [
                                ResolvedStoryListItem(
                                    entry: .text("unresolvable.key"), nested: []
                                ),
                            ]
                        ),
                    ]),
                ]
        )
    }
}
