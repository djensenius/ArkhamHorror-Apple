import Foundation

/// A `FlavorText` tree after this client's narrow, fail-closed localization boundary
/// (``StoryNarrativeLocalization``) has resolved every title/
/// ``FlavorTextEntry/i18n(key:variables:)`` key it references into human-readable text.
/// Never constructed from a governed `Read` question until every key it contains
/// resolves; if even one title or `I18nEntry` key is unresolved, malformed, or references
/// a variable this client cannot safely stringify, no `ResolvedStory` is produced at all
/// -- the whole story fails closed rather than rendering a partially-translated,
/// partially-raw-key narrative.
struct ResolvedStory: Sendable, Equatable {
    let title: String?
    let body: [ResolvedStoryEntry]
}

/// A resolved counterpart of ``FlavorTextEntry``: every entry that reached this type has
/// already had its literal text either passed through (``FlavorTextEntry/basic(text:)``) or
/// substituted from ``StoryNarrativeLocalization``'s vocabulary
/// (``FlavorTextEntry/i18n(key:variables:)``) -- there is no unresolved key left to render.
indirect enum ResolvedStoryEntry: Sendable, Equatable {
    case text(String)
    case list(items: [ResolvedStoryListItem])
}

/// A resolved counterpart of ``FlavorTextListItem``.
struct ResolvedStoryListItem: Sendable, Equatable {
    let entry: ResolvedStoryEntry
    let nested: [ResolvedStoryListItem]
}

/// This client's entire lawful narrative-localization boundary.
///
/// The pinned backend contract's `FlavorText.title` and every `FlavorTextEntry.I18nEntry`
/// `key` are i18n lookup keys, not narrative text on the wire (see ``FlavorText``'s own
/// documentation): the reference Vue client resolves them against locale bundles it ships
/// (`frontend/src/locales/en/**`) that carry genuine FFG-copyrighted scenario/campaign
/// narrative and rules-reference prose. Those bundles are not served by any backend REST
/// endpoint, and this repository has no lawful right to vendor or otherwise reproduce
/// their scenario-specific content.
///
/// The one exception is a tiny, fixed set of *generic English UI-chrome* words -- not
/// scenario or campaign narrative -- that the reference client's own scenario-agnostic
/// `base.json` reuses byte-for-byte, unchanged, across every scenario and campaign:
/// "Continue" (a button label) and "Setup" (a section heading). Those two words are safe
/// to reproduce here exactly as this client already renders "Continue" for the governed
/// `$continue` read-choice label (see `BasicChoiceQuestion.title`).
///
/// Every other `$`-prefixed title or `I18nEntry` key -- including every key the currently
/// vendored `question-read*.json` contract fixtures actually exercise -- resolves to `nil`
/// here and fails the whole story closed, on purpose: this app must never display a raw
/// i18n key as though it were finished narrative, and must never fabricate translated
/// prose it has no license to author.
enum StoryNarrativeLocalization {
    /// This client's entire lawful localization vocabulary. See this type's own
    /// documentation for why these two entries -- and only these two -- are safe to
    /// hardcode; every other key must fail closed rather than being guessed at or copied
    /// from the backend's copyrighted locale bundles.
    static let chromeVocabulary: [String: String] = [
        "continue": "Continue",
        "setup": "Setup",
    ]

    /// Resolves `flavorText` against `vocabulary` (``chromeVocabulary`` by default; a test
    /// may inject a synthetic vocabulary to exercise the substitution mechanism without
    /// depending on any real, copyrighted narrative content). Returns `nil` -- fail
    /// closed -- if any title or `I18nEntry` key is missing from `vocabulary`, or if any
    /// `{variable}` placeholder its resolved template contains cannot be losslessly
    /// substituted (see ``substituteVariables(_:variables:)``).
    static func resolvedStory(
        for flavorText: FlavorText, vocabulary: [String: String] = chromeVocabulary
    ) -> ResolvedStory? {
        guard let title = resolvedTitle(flavorText.title, vocabulary: vocabulary) else {
            return nil
        }
        var body: [ResolvedStoryEntry] = []
        body.reserveCapacity(flavorText.body.count)
        for entry in flavorText.body {
            guard let resolved = resolvedEntry(entry, vocabulary: vocabulary) else { return nil }
            body.append(resolved)
        }
        return ResolvedStory(title: title, body: body)
    }

    /// A `FlavorText.title`/`Label.label`-style field: a leading `$` marks an i18n lookup
    /// key (stripped before lookup); any other string is already literal backend-provided
    /// text (matching the reference Vue client's own `maybeFormat`/`tformat` convention --
    /// see `StoryEntry.vue`) and passes through unresolved-but-verbatim. `nil` title means
    /// no title at all, distinct from an unresolved one: the outer optional distinguishes
    /// "failed to resolve" (`nil`) from "resolved, and there simply is no title"
    /// (`.some(nil)`).
    private static func resolvedTitle(
        _ rawTitle: String?, vocabulary: [String: String]
    ) -> String?? {
        guard let rawTitle else { return .some(nil) }
        guard rawTitle.hasPrefix("$") else { return .some(rawTitle) }
        guard let resolved = vocabulary[String(rawTitle.dropFirst())] else { return nil }
        return .some(resolved)
    }

    private static func resolvedEntry(
        _ entry: FlavorTextEntry, vocabulary: [String: String]
    ) -> ResolvedStoryEntry? {
        switch entry {
        case let .basic(text):
            // `BasicEntry` is always literal backend-provided text (never an i18n lookup
            // key) per this governed slice's own contract, so it passes through
            // completely unresolved-but-verbatim -- never looked up, never fails closed.
            return .text(text)
        case let .i18n(key, variables):
            guard let template = vocabulary[key] else { return nil }
            guard let substituted = substituteVariables(template, variables: variables) else {
                return nil
            }
            return .text(substituted)
        case let .list(items):
            var resolvedItems: [ResolvedStoryListItem] = []
            resolvedItems.reserveCapacity(items.count)
            for item in items {
                guard let resolvedItem = resolvedListItem(item, vocabulary: vocabulary) else {
                    return nil
                }
                resolvedItems.append(resolvedItem)
            }
            return .list(items: resolvedItems)
        }
    }

    private static func resolvedListItem(
        _ item: FlavorTextListItem, vocabulary: [String: String]
    ) -> ResolvedStoryListItem? {
        guard let resolvedEntry = resolvedEntry(item.entry, vocabulary: vocabulary) else {
            return nil
        }
        var nested: [ResolvedStoryListItem] = []
        nested.reserveCapacity(item.nested.count)
        for nestedItem in item.nested {
            guard let resolvedNested = resolvedListItem(nestedItem, vocabulary: vocabulary) else {
                return nil
            }
            nested.append(resolvedNested)
        }
        return ResolvedStoryListItem(entry: resolvedEntry, nested: nested)
    }

    /// Substitutes vue-i18n's own named-interpolation syntax -- a bare identifier wrapped
    /// in a single pair of braces, for example `{setImgPath}` (see this contract's own
    /// `nightOfTheZealot.theGathering.setup.gatherSets` locale entry, and vue-i18n's named
    /// interpolation documentation) -- against `variables`, which the wire schema requires
    /// to always be a JSON object (possibly empty; see `FlavorTextEntry.i18n(key:variables:)`).
    ///
    /// Fails closed -- returns `nil`, never a partially-substituted string -- for any
    /// placeholder whose identifier isn't a valid `[A-Za-z_][A-Za-z0-9_]*` token, any
    /// unterminated `{` with no matching `}`, any identifier missing from `variables`, and
    /// any variable value that isn't a JSON string or number. This client implements no
    /// pluralization, rich HTML markup, or other ICU MessageFormat feature the reference
    /// client's fuller `t()`/`formatContent` pipeline supports: that is an intentional,
    /// documented limitation, never silently exercised in production, since every
    /// production `I18nEntry` key this client currently resolves (``chromeVocabulary``'s
    /// two entries) carries no variables at all -- this mechanism exists to be provably
    /// correct and testable via an injected vocabulary, not to fully replicate vue-i18n.
    static func substituteVariables(_ template: String, variables: JSONValue) -> String? {
        guard case let .object(variableObject) = variables else { return nil }
        var result = ""
        var remainder = Substring(template)
        while let openBrace = remainder.firstIndex(of: "{") {
            result += remainder[remainder.startIndex ..< openBrace]
            let afterOpen = remainder.index(after: openBrace)
            guard let closeBrace = remainder[afterOpen...].firstIndex(of: "}") else {
                return nil
            }
            let identifier = remainder[afterOpen ..< closeBrace]
            guard isValidPlaceholderIdentifier(identifier) else { return nil }
            guard let value = variableObject[String(identifier)] else { return nil }
            guard let stringValue = stringifyVariable(value) else { return nil }
            result += stringValue
            remainder = remainder[remainder.index(after: closeBrace)...]
        }
        result += remainder
        return result
    }

    private static func isValidPlaceholderIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else { return false }
        return text.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Only `String`/`number` wire variable values stringify losslessly for narrative
    /// substitution; every other `JSONValue` case (`null`, `bool`, `array`, `object`) has
    /// no unambiguous, lossless plain-text rendering here and fails closed instead of
    /// guessing at one.
    private static func stringifyVariable(_ value: JSONValue) -> String? {
        switch value {
        case let .string(text):
            text
        case let .number(number):
            number.description
        case .null, .bool, .array, .object:
            nil
        }
    }
}
