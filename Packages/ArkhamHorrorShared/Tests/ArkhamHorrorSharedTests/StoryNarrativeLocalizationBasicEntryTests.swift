@testable import ArkhamHorrorShared
import Foundation
import Testing

/// `BasicEntry.text`'s `$`-prefix i18n-lookup semantics (issue
/// djensenius/ArkhamHorror-Apple#35, independent-review blocker 1 on PR #36): the
/// reference Vue client (`FormattedEntry.vue`, pinned commit `52c7ee3b`) resolves a
/// `$`-prefixed `BasicEntry.text` via the exact same plain vocabulary lookup as `title`
/// (no `{variable}` substitution, unlike `I18nEntry`) -- a non-`$` `BasicEntry.text`
/// remains literal, and any `$`-prefixed key absent from the vocabulary fails the whole
/// story closed rather than rendering the raw identifier. Split out of
/// `StoryNarrativeLocalizationTests.swift` to keep that file under the repository's
/// `file_length`/`type_body_length` lint limits.
extension StoryNarrativeLocalizationTests {
    @Test("A $continue or $setup BasicEntry resolves via the real default chrome vocabulary")
    func basicEntryDollarPrefixedChromeKeysResolveViaDefaultVocabulary() {
        let continueText = FlavorText(title: nil, body: [.basic(text: "$continue")])
        #expect(
            StoryNarrativeLocalization.resolvedStory(for: continueText)?.body
                == [.text("Continue")]
        )
        let setupText = FlavorText(title: nil, body: [.basic(text: "$setup")])
        #expect(
            StoryNarrativeLocalization.resolvedStory(for: setupText)?.body == [.text("Setup")]
        )
    }

    @Test(
        "A real, unmapped $-prefixed scenario-narrative BasicEntry key fails the whole story closed"
    )
    func basicEntryUnmappedRealScenarioKeyFailsClosed() {
        // The exact real dotted key `question-read.json` itself carries as an `I18nEntry`
        // (see `realReadFixtureFailsClosed`) -- copyrighted Arkham Horror scenario
        // narrative, never lawfully in `chromeVocabulary` -- reused here as a `BasicEntry`
        // to prove the fix applies uniformly regardless of which entry kind carries it.
        let flavorText = FlavorText(
            title: nil,
            body: [.basic(text: "$nightOfTheZealot.theGathering.setup.gatherSets")]
        )
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText) == nil)
    }

    @Test("BasicEntry text with no leading $ is literal and passes through unchanged")
    func basicEntryLiteralNonDollarContentPassesThroughUnchanged() {
        let flavorText = FlavorText(
            title: nil, body: [.basic(text: "Not an i18n key"), .basic(text: "")]
        )
        #expect(
            StoryNarrativeLocalization.resolvedStory(for: flavorText)?.body
                == [.text("Not an i18n key"), .text("")]
        )
    }

    @Test("A bare $ with an empty key, and an unrecognized $-prefixed key, both fail closed")
    func basicEntryBareDollarAndInvalidKeyFailClosed() {
        #expect(
            StoryNarrativeLocalization.resolvedStory(
                for: FlavorText(title: nil, body: [.basic(text: "$")])
            ) == nil
        )
        #expect(
            StoryNarrativeLocalization.resolvedStory(
                for: FlavorText(title: nil, body: [.basic(text: "$ not a real key!")])
            ) == nil
        )
    }

    @Test("A ListEntry mixing a resolvable and an unresolvable $-prefixed BasicEntry fails closed")
    func recursiveListEntryMixedDollarPrefixedBasicEntryFailsClosed() {
        let flavorText = FlavorText(
            title: nil,
            body: [
                .list(items: [
                    FlavorTextListItem(entry: .basic(text: "$continue"), nested: []),
                    FlavorTextListItem(entry: .basic(text: "$unknownVocabularyKey"), nested: []),
                ]),
            ]
        )
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText) == nil)
    }
}
