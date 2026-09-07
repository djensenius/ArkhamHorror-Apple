@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog resolver")
// swiftlint:disable:next type_body_length
struct LocaleCatalogResolverTests {
    private let revision = "1.0123456789abcdef0123456789abcdef"

    // swiftlint:disable:next function_body_length
    private func snapshot(
        selectedLocale: String = "en",
        english: [String: LocaleCatalogEntry],
        translated: [String: LocaleCatalogEntry] = [:]
    ) -> LocaleCatalogSnapshot {
        let digest = SyntheticLocaleCatalogDocuments.hex
        let englishDescriptor = LocaleCatalogChunkDescriptor(
            pack: "story",
            path: LocaleCatalogGrammar.chunkPath(forDigest: digest),
            bytes: 1,
            sha256: digest,
            keys: english.count,
            unsupportedKeys: 0
        )
        let translationDescriptor = LocaleCatalogChunkDescriptor(
            pack: "story",
            path: LocaleCatalogGrammar.chunkPath(forDigest: String(repeating: "b", count: 64)),
            bytes: 1,
            sha256: String(repeating: "b", count: 64),
            keys: translated.count,
            unsupportedKeys: 0
        )
        let includesFrench = selectedLocale == "fr" || !translated.isEmpty
        let locales: [LocaleCatalogLocaleRecord] = includesFrench
            ? [
                LocaleCatalogLocaleRecord(
                    locale: "fr", fallback: "en", chunks: [translationDescriptor],
                    keys: translated.count, bytes: 1
                ),
                LocaleCatalogLocaleRecord(
                    locale: "en", fallback: nil, chunks: [englishDescriptor],
                    keys: english.count, bytes: 1
                ),
            ]
            : [
                LocaleCatalogLocaleRecord(
                    locale: "en", fallback: nil, chunks: [englishDescriptor],
                    keys: english.count, bytes: 1
                ),
            ]
        let manifest = LocaleCatalogManifest(
            catalogRevision: revision,
            defaultLocale: "en",
            locales: locales,
            languageResolution: ["en": "en", "fr": "fr", "fr-CA": "fr"],
            totals: LocaleCatalogTotals(
                locales: locales.count,
                chunks: locales.count,
                bytes: locales.count,
                keys: english.count + translated.count,
                unsupportedKeys: 0
            )
        )
        let chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [
            LocaleCatalogChunkKey(locale: "en", pack: "story"): LocaleCatalogChunk(
                locale: "en", fallback: nil, pack: "story", entries: english
            ),
            LocaleCatalogChunkKey(locale: "fr", pack: "story"): LocaleCatalogChunk(
                locale: "fr", fallback: "en", pack: "story", entries: translated
            ),
        ]
        return LocaleCatalogSnapshot(
            identity: LocaleCatalogIdentity(
                endpoint: URL(
                    string: "https://catalog.example.test/locale-catalog/manifest.json"
                )!,
                catalogRevision: revision,
                locale: selectedLocale,
                manifestSha256: digest
            ),
            manifest: manifest,
            chunks: chunks
        )
    }

    private func message(_ nodes: [LocaleCatalogNode]) -> LocaleCatalogEntry {
        .message(nodes: nodes, variables: [])
    }

    private func number(_ text: String) -> JSONValue {
        guard let value = try? JSONNumber(exactDecimalLiteral: text) else {
            fatalError("Synthetic JSON number must be valid: \(text)")
        }
        return .number(value)
    }

    @Test("Resolver follows the manifest fallback graph and language resolution table")
    func resolverFollowsFallbacks() {
        let resolver = LocaleCatalogResolver(snapshot: snapshot(
            selectedLocale: "fr",
            english: ["story.body": message([.text("English")])],
            translated: [:]
        ))
        #expect(resolver.render(
            key: "story.body", variables: .object([:])
        ) == .success([.text("English")]))
        #expect(LocaleCatalogSnapshot.resolveLocale(
            preferredLanguages: ["fr-CA-x-private"],
            table: ["fr-CA": "fr"],
            supportedLocales: ["en", "fr"],
            defaultLocale: "en"
        ) == "fr")
    }

    @Test("Resolver fails the complete entry for link cycles and missing variables")
    func resolverFailsClosedForLinksAndVariables() {
        let cycleResolver = LocaleCatalogResolver(snapshot: snapshot(english: [
            "story.first": message([
                .linked(target: .staticKey("story.second"), modifier: nil),
            ]),
            "story.second": message([
                .linked(target: .staticKey("story.first"), modifier: nil),
            ]),
        ]))
        #expect(cycleResolver.render(
            key: "story.first", variables: .object([:])
        ) == .failure(.linkCycle))

        let variableResolver = LocaleCatalogResolver(snapshot: snapshot(english: [
            "story.body": message([
                .variable(name: "name", source: .named, isIcon: false),
            ]),
        ]))
        #expect(variableResolver.render(
            key: "story.body", variables: .object([:])
        ) == .failure(.missingVariable))
    }

    @Test("Fallback parent links retain their supplying locale instead of restarting at selection")
    func fallbackParentLinkKeepsParentLocale() {
        let resolver = LocaleCatalogResolver(snapshot: snapshot(
            selectedLocale: "fr",
            english: [
                "story.parent": message([
                    .linked(target: .staticKey("story.term"), modifier: nil),
                ]),
                "story.term": message([.text("English term")]),
            ],
            translated: ["story.term": message([.text("French term")])]
        ))
        #expect(resolver.render(
            key: "story.parent", variables: .object([:])
        ) == .success([.text("English term")]))
    }

    @Test("Plural selection matches Vue I18n's default two, three, and larger case layouts")
    func pluralSelectionMatchesVueI18n() {
        let twoCase = LocaleCatalogResolver(snapshot: snapshot(english: [
            "story.two": .plural(
                cases: [[.text("one")], [.text("other")]],
                variables: []
            ),
        ]))
        #expect(twoCase.render(
            key: "story.two", variables: .object(["count": number("0")])
        ) == .success([.text("other")]))
        #expect(twoCase.render(
            key: "story.two", variables: .object(["count": number("-1")])
        ) == .success([.text("one")]))
        #expect(twoCase.render(
            key: "story.two", variables: .object(["n": number("2")])
        ) == .success([.text("other")]))

        let threeOrMore = LocaleCatalogResolver(snapshot: snapshot(english: [
            "story.many": .plural(
                cases: [[.text("zero")], [.text("one")], [.text("other")], [.text("unused")]],
                variables: []
            ),
        ]))
        #expect(threeOrMore.render(
            key: "story.many", variables: .object(["count": number("0")])
        ) == .success([.text("zero")]))
        #expect(threeOrMore.render(
            key: "story.many", variables: .object(["count": number("1")])
        ) == .success([.text("one")]))
        #expect(threeOrMore.render(
            key: "story.many", variables: .object(["count": number("2")])
        ) == .success([.text("other")]))
        #expect(threeOrMore.render(
            key: "story.many", variables: .object(["count": number("99")])
        ) == .success([.text("other")]))
    }

    @Test("Plural and image entries fail closed for an invalid selector or unavailable renderer")
    func pluralAndImagesFailClosed() {
        let resolver = LocaleCatalogResolver(snapshot: snapshot(english: [
            "story.oneCase": .plural(cases: [[.text("only")]], variables: []),
            "story.plural": .plural(
                cases: [[.text("zero")], [.text("one")], [.text("other")]],
                variables: []
            ),
            "story.image": message([
                .image(role: .card, assetPath: "cards/example.png", alt: "Example"),
            ]),
        ]))
        #expect(resolver.render(
            key: "story.oneCase", variables: .object(["count": number("1")])
        ) == .failure(.unsupportedEntry))
        #expect(resolver.render(
            key: "story.plural", variables: .object([:])
        ) == .failure(.missingVariable))
        #expect(resolver.render(
            key: "story.plural", variables: .object(["count": .string("two")])
        ) == .failure(.unsupportedVariableValue))
        #expect(resolver.render(
            key: "story.plural", variables: .object(["count": number("1.5")])
        ) == .failure(.unsupportedVariableValue))
        #expect(resolver.render(
            key: "story.image", variables: .object([:])
        ) == .failure(.unsupportedEntry))
    }

    @Test("Closed chunk parsing rejects unsupported nodes and descriptor count mismatches")
    func closedChunkParsingRejectsUnsupportedContent() throws {
        let unsupportedNode = try LosslessJSONParser.parse(
            Data(
                """
                {"schemaVersion":"1.0.0","locale":"en","fallback":null,"pack":"story",\
                "entries":{"story.body":{"form":"message","nodes":[{"type":"html","value":"x"}],\
                "variables":[]}}}
                """.utf8
            )
        )
        #expect(LocaleCatalogChunk.validate(
            unsupportedNode,
            expectedLocale: "en",
            expectedFallback: nil,
            expectedPack: "story",
            expectedKeys: 1,
            expectedUnsupportedKeys: 0
        ) == .failure(.malformedChunk))

        let validNode = try LosslessJSONParser.parse(
            Data(
                """
                {"schemaVersion":"1.0.0","locale":"en","fallback":null,"pack":"story",\
                "entries":{"story.body":{"form":"message","nodes":[{"type":"text","value":"x"}],\
                "variables":[]}}}
                """.utf8
            )
        )
        #expect(LocaleCatalogChunk.validate(
            validNode,
            expectedLocale: "en",
            expectedFallback: nil,
            expectedPack: "story",
            expectedKeys: 2,
            expectedUnsupportedKeys: 0
        ) == .failure(.malformedChunk))
        #expect(LocaleCatalogChunk.validate(
            validNode,
            expectedLocale: "fr",
            expectedFallback: "en",
            expectedPack: "story",
            expectedKeys: 1,
            expectedUnsupportedKeys: 0
        ) == .failure(.malformedChunk))
        #expect(LocaleCatalogChunk.validate(
            validNode,
            expectedLocale: "en",
            expectedFallback: nil,
            expectedPack: "core",
            expectedKeys: 1,
            expectedUnsupportedKeys: 0
        ) == .failure(.malformedChunk))
    }

    @Test("Story resolution keeps the title and every body entry from one snapshot")
    func storyResolutionIsCoherent() {
        let resolver = LocaleCatalogResolver(snapshot: snapshot(english: [
            "story.title": message([.text("Revision one")]),
            "story.body": message([.heading(level: 2, children: [.text("Body one")])]),
        ]))
        let story = FlavorText(
            title: "$story.title",
            body: [.i18n(key: "story.body", variables: .object([:]))]
        )
        let resolution = StoryNarrativeLocalization.resolve(
            story,
            resolver: resolver,
            catalogUnavailability: nil
        )
        #expect(resolution == .resolved(ResolvedStory(
            title: "Revision one",
            body: [.nodes([.heading(level: 2, children: [.text("Body one")])])]
        )))
    }
}
