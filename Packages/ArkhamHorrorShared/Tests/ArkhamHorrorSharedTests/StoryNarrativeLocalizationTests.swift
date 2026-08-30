@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Production-fixture-driven and synthetic-vocabulary coverage for
/// ``StoryNarrativeLocalization``, this client's entire lawful, fail-closed narrative
/// localization boundary (issue djensenius/ArkhamHorror-Apple#35, independent-review
/// blocker 2). Proves the real, currently-vendored `question-read.json` fails closed
/// (none of its 4 real keys are in ``StoryNarrativeLocalization/chromeVocabulary``), that
/// the substitution/`$`-prefix/`BasicEntry`-literal/recursive-`ListEntry` mechanisms are
/// each independently correct against an injected synthetic vocabulary (never real,
/// copyrighted narrative content), and that every malformed/missing/unsupported-type input
/// fails closed rather than partially substituting or guessing.
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
        "question-read.json fails closed: dotted i18n keys are not in the safe vocabulary"
    )
    func realReadFixtureFailsClosed() throws {
        let flavorText = try readStory(from: "question-read")
        #expect(flavorText.title == "$setup")
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText) == nil)
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

    @Test("An unresolvable $-prefixed title fails the whole story closed")
    func unresolvableDollarPrefixedTitleFailsClosed() {
        let flavorText = FlavorText(title: "$unknownVocabularyKey", body: [])
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText) == nil)
    }

    // MARK: - BasicEntry is always literal, never looked up

    @Test("BasicEntry text is always literal, even if it happens to start with $")
    func basicEntryNeverLooksUpEvenWithDollarPrefix() {
        let flavorText = FlavorText(title: nil, body: [.basic(text: "$continue")])
        let resolved = StoryNarrativeLocalization.resolvedStory(for: flavorText)
        // Unlike `title`, `BasicEntry.text` is never treated as an i18n key -- it passes
        // through completely verbatim, including its literal "$continue" characters.
        #expect(resolved?.body == [.text("$continue")])
    }

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

    @Test("An I18nEntry key missing from the vocabulary fails the whole story closed")
    func i18nEntryMissingFromVocabularyFailsClosed() {
        let flavorText = FlavorText(
            title: nil, body: [.i18n(key: "notInVocabulary", variables: .object([:]))]
        )
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText) == nil)
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
        "A single unresolvable entry nested deep inside a ListEntry fails the whole story closed"
    )
    func recursiveListEntryPartialFailureFailsWholeStoryClosed() {
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
            StoryNarrativeLocalization.resolvedStory(for: flavorText, vocabulary: vocabulary)
                == nil
        )
    }
}
