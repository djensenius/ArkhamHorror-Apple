// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import CoreText
import CryptoKit
import Foundation
import Testing

@Suite("Web icon font glyph mapping")
struct WebIconFontGlyphMappingTests {
    @Test("Story icon glyph table matches the icons.css fixture")
    func glyphTableMatchesIconsCSSFixture() throws {
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: fixtureData(named: "web-icons-css-task-1.22.1")
        )
        #expect(
            fixture.provenance
                == "fork 4203738708b0ad2d3cff426b4ce2e6b3d9904fec frontend/src/styles/icons.css"
        )
        let actual = StoryIconGlyph.storyGlyphs.map(WebIconFontFixtureMapping.init(glyph:))
        #expect(actual == fixture.mappings)
    }

    @Test("Renderer uses the resolved PostScript name rather than the CSS family")
    func rendererUsesResolvedPostScriptName() {
        let postScriptName = "RealArkhamIconsPS"
        #expect(postScriptName != WebIconFontFamily.arkhamIcons.rawValue)
        let onlyArkhamIcons = WebIconFontAvailability(registrations: [
            .arkhamIcons: registration(.arkhamIcons, postScriptName: postScriptName),
        ])
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.skull),
                iconFonts: onlyArkhamIcons
            ) == .webGlyph(iconName: "skull", fontName: postScriptName, glyph: "\u{E910}")
        )
    }

    @Test("Renderer falls back for a missing glyph inside a registered family")
    func rendererFallsBackForMissingGlyphInRegisteredFamily() {
        let postScriptName = "PartialArkhamIconsPS"
        let withoutSkull = WebIconFontAvailability(registrations: [
            .arkhamIcons: registration(
                .arkhamIcons,
                postScriptName: postScriptName,
                excluding: ["skull"]
            ),
        ])
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.skull),
                iconFonts: withoutSkull
            ) == .systemImage(name: "circle.hexagongrid.fill")
        )
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.cultist),
                iconFonts: withoutSkull
            ) == .webGlyph(iconName: "cultist", fontName: postScriptName, glyph: "\u{E911}")
        )
    }

    @Test("Semantic icon accessibility labels stay unchanged")
    func accessibilityLabelIsSemanticTextNotDecorativeGlyph() {
        let nodes: [StoryNode] = [
            .text("Resolve "),
            .semanticIcon(.chaosToken(.elderThing)),
            .text(" and "),
            .semanticIcon(.skill(.willpower)),
            .text("."),
        ]
        #expect(
            StoryNodePresentation.accessibilityLabel(for: nodes)
                == "Resolve elder thing and willpower."
        )
    }

    @Test("Choice label literal icon placeholders become story inline glyph nodes")
    func choiceLabelLiteralIconPlaceholdersBecomeInlineGlyphNodes() throws {
        let nodes = try #require(StoryIconInlineParser.nodes(for: "Choose {skull}"))
        #expect(nodes == [.text("Choose "), .semanticIcon(.chaosToken(.skull))])
        #expect(StoryNodePresentation.accessibilityLabel(for: nodes) == "Choose skull")

        let iconFonts = WebIconFontAvailability(registrations: [
            .arkhamIcons: registration(.arkhamIcons, postScriptName: "arkhamicons"),
        ])
        #expect(
            StoryInlineTextRenderer.semanticIconTextRun(
                for: .chaosToken(.skull),
                iconFonts: iconFonts,
                textStyle: .body
            ) == StoryInlineSemanticIconTextRun(
                run: .webGlyph(iconName: "skull", fontName: "arkhamicons", glyph: "\u{E910}"),
                pointSize: StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .body)
            )
        )
    }

    @Test("Literal icon parser preserves brace edges and continues after misses")
    func literalIconParserHandlesBraceEdges() throws {
        #expect(StoryIconInlineParser.nodes(for: "Choose {future}") == nil)
        #expect(
            try #require(StoryIconInlineParser.nodes(for: "{future} then {skull}"))
                == [.text("{future} then "), .semanticIcon(.chaosToken(.skull))]
        )
        #expect(StoryIconInlineParser.nodes(for: "Choose {skull") == nil)
        #expect(
            try #require(StoryIconInlineParser.nodes(for: "{skull} and {future"))
                == [.semanticIcon(.chaosToken(.skull)), .text(" and {future")]
        )
        #expect(
            try #require(StoryIconInlineParser.nodes(for: "{x {skull}"))
                == [.text("{x "), .semanticIcon(.chaosToken(.skull))]
        )
        #expect(
            try #require(StoryIconInlineParser.nodes(for: "{willpower}{skull}"))
                == [.semanticIcon(.skill(.willpower)), .semanticIcon(.chaosToken(.skull))]
        )
        // Raw labels match the web replaceIcons path; catalog `{{` escaping is upstream.
        #expect(
            try #require(StoryIconInlineParser.nodes(for: "{{skull}}"))
                == [.text("{"), .semanticIcon(.chaosToken(.skull)), .text("}")]
        )
    }

    @Test("Board chaos-token glyphs use face glyphs and honest fallbacks")
    func boardChaosTokenGlyphsUseFaceGlyphsAndFallbacks() throws {
        let iconFonts = WebIconFontAvailability(registrations: [
            .arkhamIcons: registration(.arkhamIcons, postScriptName: "arkhamicons"),
        ])
        let boardNodes = BoardChaosTokenGlyphPresentation.nodes(for: .skull)
        let requiredBoardNodes = try #require(boardNodes)
        #expect(requiredBoardNodes == [.semanticIcon(.chaosToken(.skull))])
        #expect(StoryInlineTextRenderer.text(
            for: requiredBoardNodes,
            iconFonts: iconFonts,
            textStyle: .caption
        ) != nil)
        #expect(
            BoardChaosTokenGlyphPresentation.run(for: .skull, iconFonts: iconFonts)
                == .webGlyph(iconName: "skull", fontName: "arkhamicons", glyph: "\u{E910}")
        )
        #expect(
            StoryInlineTextRenderer.semanticIconTextRun(
                for: .chaosToken(.skull),
                iconFonts: iconFonts,
                textStyle: .caption
            ) == StoryInlineSemanticIconTextRun(
                run: .webGlyph(iconName: "skull", fontName: "arkhamicons", glyph: "\u{E910}"),
                pointSize: StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .caption)
            )
        )
        #expect(
            BoardChaosTokenGlyphPresentation.run(
                for: .skull,
                iconFonts: WebIconFontAvailability()
            ) == .systemImage(name: "circle.hexagongrid.fill")
        )
        #expect(BoardChaosTokenGlyphPresentation.nodes(for: .zero) == nil)
        #expect(
            BoardChaosTokenGlyphPresentation.run(for: .zero, iconFonts: iconFonts)
                == .systemImage(name: "circle.hexagongrid.fill")
        )
    }

    private func registration(
        _ family: WebIconFontFamily,
        postScriptName: String,
        excluding excludedIconNames: Set<String> = []
    ) -> WebIconFontRegistration {
        WebIconFontRegistration(
            family: family,
            postScriptName: postScriptName,
            supportedScalars: Set(StoryIconGlyph.all.compactMap { glyph in
                guard glyph.family == family, !excludedIconNames.contains(glyph.iconName) else {
                    return nil
                }
                return glyph.scalar.value
            })
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private struct Fixture: Decodable {
        let provenance: String
        let mappings: [WebIconFontFixtureMapping]
    }
}

private struct WebIconFontFixtureMapping: Decodable, Equatable {
    let iconName: String
    let cssClass: String
    let family: String
    let codepoint: String

    init(iconName: String, cssClass: String, family: String, codepoint: String) {
        self.iconName = iconName
        self.cssClass = cssClass
        self.family = family
        self.codepoint = codepoint
    }

    init(glyph: StoryIconGlyph) {
        iconName = glyph.iconName
        cssClass = glyph.cssClass
        family = glyph.family.rawValue
        codepoint = String(format: "%04X", glyph.scalar.value)
    }
}

@Suite("Web icon font loader")
// swiftlint:disable:next type_body_length
struct WebIconFontLoaderTests {
    @Test("Loader resolves fonts on the configured server origin")
    func fontURLsUseConfiguredServerOrigin() throws {
        let profile = try ServerProfile.custom(
            displayName: "Prefixed",
            rawURL: "https://game.example.test/prefix"
        )
        let arkhamIcons = WebIconFontSource(
            family: .arkhamIcons,
            path: "/fonts/arkhamicons.ttf"
        )
        #expect(
            WebIconFontLoader.url(for: arkhamIcons, profile: profile)?.absoluteString
                == "https://game.example.test/fonts/arkhamicons.ttf"
        )
    }

    @Test("Loader enforces the per-font size cap")
    func loaderEnforcesSizeCap() async throws {
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: Data(repeating: 0x41, count: 512 * 1024 + 1)),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar()
        )
        let report = try await loader.loadFonts(for: profile())
        #expect(report.failures[.arkham] == .tooLarge)
        #expect(!report.loadedFamilies.contains(.arkham))
    }

    @Test("Loader rejects invalid font data and reports fallback state")
    func loaderRejectsInvalidData() async throws {
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: Data("not-a-font".utf8)),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar()
        )
        let report = try await loader.loadFonts(for: profile())
        #expect(report.failures[.arkham] == .invalidFont)
        #expect(report.availability == WebIconFontAvailability())
    }

    @Test("Loader serves a disk cache hit before background revalidation")
    func loaderUsesDiskCacheHit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let firstTransport = FakeWebIconFontTransport.validFonts()
        let firstLoader = WebIconFontLoader(
            transport: firstTransport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let firstReport = try await firstLoader.loadFonts(for: profile())
        #expect(firstReport.loadedFamilies == Set(WebIconFontFamily.allCases))
        #expect(await firstTransport.totalFetchCount() == WebIconFontSources.required.count)

        let secondTransport = FakeWebIconFontTransport(
            responses: Dictionary(uniqueKeysWithValues: WebIconFontSources.required.map { source in
                (source.path, FakeWebIconFontTransport.Response.success(data: Data(), status: 304))
            })
        )
        let secondLoader = WebIconFontLoader(
            transport: secondTransport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let secondReport = try await secondLoader.loadFonts(for: profile())
        #expect(secondReport.loadedFamilies == Set(WebIconFontFamily.allCases))
        #expect(secondReport.failures.isEmpty)
        await waitForTotalFetchCount(WebIconFontSources.required.count, transport: secondTransport)
        #expect(await secondTransport.totalFetchCount() == WebIconFontSources.required.count)
    }

    @Test("One failed family does not disable registered families")
    func loaderFallsBackPerFamily() async throws {
        var responses = FakeWebIconFontTransport.validFontResponses()
        responses["/fonts/icon.woff2"] = .success(data: Data("invalid-icons".utf8))
        let loader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: responses),
            registrar: PrefixWebIconFontRegistrar()
        )
        let report = try await loader.loadFonts(for: profile())
        #expect(report.loadedFamilies == [.arkham, .arkhamIcons, .arkhamSlim])
        #expect(report.failures[.icons] == .invalidFont)
        #expect(
            report.availability.registrations[.arkhamIcons]?.postScriptName
                == "arkhamicons"
        )
        #expect(report.availability.registrations[.arkhamIcons]?.postScriptName != "ArkhamIcons")

        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.skull),
                iconFonts: report.availability
            ) == .webGlyph(iconName: "skull", fontName: "arkhamicons", glyph: "\u{E910}")
        )
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.blood),
                iconFonts: report.availability
            ) == .systemImage(name: "circle.hexagongrid.fill")
        )
    }

    @Test("Loader keeps registered family but falls back for its missing glyph")
    func loaderPublishesOnlySupportedGlyphs() async throws {
        var responses = FakeWebIconFontTransport.validFontResponses()
        responses["/fonts/arkhamicons.ttf"] = .success(
            data: FakeWebIconFontTransport.syntheticFontData(
                family: .arkhamIcons,
                excluding: ["skull"]
            )
        )
        let loader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: responses),
            registrar: PrefixWebIconFontRegistrar()
        )
        let report = try await loader.loadFonts(for: profile())
        #expect(report.loadedFamilies.contains(.arkhamIcons))
        #expect(report.availability.registrations[.arkhamIcons]?.postScriptName == "arkhamicons")
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.skull),
                iconFonts: report.availability
            ) == .systemImage(name: "circle.hexagongrid.fill")
        )
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.cultist),
                iconFonts: report.availability
            ) == .webGlyph(iconName: "cultist", fontName: "arkhamicons", glyph: "\u{E911}")
        )
    }

    @Test("Loader reports non-200 font responses")
    func loaderReportsNon200Status() async throws {
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: Data("error".utf8), status: 500),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar()
        )

        let report = try await loader.loadFonts(for: profile())

        #expect(report.failures[.arkham] == .unexpectedStatus(500))
        #expect(!report.loadedFamilies.contains(.arkham))
    }

    @Test("Loader revalidates a disk cache hit with conditional validators")
    func loaderRevalidatesDiskCacheHitWithConditionalHeaders() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let source = WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf")
        let url = try #require(WebIconFontLoader.url(for: source, profile: profile()))
        let cachedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "cached-arkham"
        )
        let cachedKey = WebIconFontCacheKey(
            url: url,
            etag: "\"cached\"",
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
            data: cachedData
        )
        try cache.store(data: cachedData, key: cachedKey)
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: Data(), status: 304),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )

        let report = try await loader.loadFonts(for: profile())
        await loader.awaitPendingRevalidations()

        #expect(report.availability.registrations[.arkham]?.postScriptName == "cached-arkham")
        let requests = await transport.requests(for: "/fonts/arkham.ttf")
        #expect(requests.count == 1)
        #expect(requests.first?.ifNoneMatch == "\"cached\"")
        #expect(requests.first?.ifModifiedSince == "Wed, 21 Oct 2015 07:28:00 GMT")

        let offlineLoader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: [:]),
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let offlineReport = try await offlineLoader.loadFonts(for: profile())
        #expect(
            offlineReport.availability.registrations[.arkham]?.postScriptName == "cached-arkham"
        )
    }

    @Test("A valid 200 revalidation replaces the disk cache payload")
    func validRevalidationReplacesDiskCachePayload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let source = WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf")
        let url = try #require(WebIconFontLoader.url(for: source, profile: profile()))
        let cachedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "old-arkham"
        )
        let oldKey = WebIconFontCacheKey(
            url: url, etag: "\"old\"", lastModified: nil, data: cachedData
        )
        try cache.store(data: cachedData, key: oldKey)
        let oldPayloadURL = payloadURL(root: root, key: oldKey)
        #expect(FileManager.default.fileExists(atPath: oldPayloadURL.path))
        let refreshedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "new-arkham"
        )
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: refreshedData, etag: "\"new\""),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )

        let report = try await loader.loadFonts(for: profile())
        await loader.awaitPendingRevalidations()
        #expect(report.availability.registrations[.arkham]?.postScriptName == "old-arkham")

        let newKey = WebIconFontCacheKey(
            url: url, etag: "\"new\"", lastModified: nil, data: refreshedData
        )
        #expect(!FileManager.default.fileExists(atPath: oldPayloadURL.path))
        #expect(FileManager.default.fileExists(atPath: payloadURL(root: root, key: newKey).path))

        let offlineLoader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: [:]),
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let offlineReport = try await offlineLoader.loadFonts(for: profile())
        #expect(offlineReport.availability.registrations[.arkham]?.postScriptName == "new-arkham")
    }

    @Test("Memory cache hits revalidate once and a valid 200 replaces the cache")
    func memoryCacheHitRevalidatesAndStoresValid200() async throws {
        let oldData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "old-memory-arkham"
        )
        let newData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "new-memory-arkham"
        )
        let transport = FakeWebIconFontTransport(scriptedResponses: memoryRevalidationScript(
            oldData: oldData,
            newData: newData
        ))
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar()
        )

        let firstReport = try await loader.loadFonts(for: profile())
        #expect(
            firstReport.availability.registrations[.arkham]?.postScriptName
                == "old-memory-arkham"
        )
        #expect(await transport.totalFetchCount() == WebIconFontSources.required.count)

        let secondReport = try await loader.loadFonts(for: profile())
        #expect(
            secondReport.availability.registrations[.arkham]?.postScriptName
                == "old-memory-arkham"
        )
        await loader.awaitPendingRevalidations()

        let arkhamRequests = await transport.requests(for: "/fonts/arkham.ttf")
        #expect(arkhamRequests.count == 2)
        #expect(arkhamRequests.last?.ifNoneMatch == "\"old-memory\"")

        let thirdReport = try await loader.loadFonts(for: profile())
        #expect(
            thirdReport.availability.registrations[.arkham]?.postScriptName
                == "new-memory-arkham"
        )
        #expect(await transport.requests(for: "/fonts/arkham.ttf").count == 2)
    }

    @Test("A failed revalidation keeps the disk cache payload")
    func failedRevalidationKeepsDiskCachePayload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let source = WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf")
        let url = try #require(WebIconFontLoader.url(for: source, profile: profile()))
        let cachedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "kept-arkham"
        )
        try cache.store(
            data: cachedData,
            key: WebIconFontCacheKey(
                url: url, etag: "\"kept\"", lastModified: nil, data: cachedData
            )
        )
        let refreshedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "bad-status-arkham"
        )
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: refreshedData, etag: "\"bad\"", status: 500),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )

        _ = try await loader.loadFonts(for: profile())
        await loader.awaitPendingRevalidations()

        let offlineLoader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: [:]),
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let offlineReport = try await offlineLoader.loadFonts(for: profile())
        #expect(offlineReport.availability.registrations[.arkham]?.postScriptName == "kept-arkham")
    }

    @Test("A 200 revalidation with an invalid font keeps the disk cache payload")
    func invalidFontRevalidationKeepsDiskCachePayload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let source = WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf")
        let url = try #require(WebIconFontLoader.url(for: source, profile: profile()))
        let cachedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "kept-after-invalid-arkham"
        )
        try cache.store(
            data: cachedData,
            key: WebIconFontCacheKey(
                url: url, etag: "\"kept\"", lastModified: nil, data: cachedData
            )
        )
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: Data("invalid-font".utf8), etag: "\"bad\""),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )

        _ = try await loader.loadFonts(for: profile())
        await loader.awaitPendingRevalidations()

        let offlineLoader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: [:]),
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let offlineReport = try await offlineLoader.loadFonts(for: profile())
        #expect(
            offlineReport.availability.registrations[.arkham]?.postScriptName
                == "kept-after-invalid-arkham"
        )
    }

    @Test("A stale 200 revalidation is discarded")
    func staleRevalidationIsDiscarded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let source = WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf")
        let url = try #require(WebIconFontLoader.url(for: source, profile: profile()))
        let cachedData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "old-arkham"
        )
        try cache.store(
            data: cachedData,
            key: WebIconFontCacheKey(
                url: url, etag: "\"old\"", lastModified: nil, data: cachedData
            )
        )
        let transport = GatedWebIconFontTransport()
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )

        _ = try await loader.loadFonts(for: profile())
        await transport.waitUntilPending(1)
        let newerData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "newer-arkham"
        )
        await loader.replaceCachedFontForTesting(
            url: url,
            data: newerData,
            etag: "\"newer\""
        )
        let staleData = FakeWebIconFontTransport.syntheticFontData(
            family: .arkham,
            postScriptName: "stale-arkham"
        )
        await transport.resumeOldest(with: WebIconFontHTTPResponse(
            statusCode: 200,
            etag: "\"stale\"",
            data: staleData
        ))
        await loader.awaitPendingRevalidations()

        let offlineLoader = WebIconFontLoader(
            transport: FakeWebIconFontTransport(responses: [:]),
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let offlineReport = try await offlineLoader.loadFonts(for: profile())
        #expect(offlineReport.availability.registrations[.arkham]?.postScriptName == "newer-arkham")
    }

    @Test("A corrupt cache entry triggers a fresh download")
    func corruptCacheEntryTriggersRedownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WebIconFontDiskCache(root: root)
        let source = WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf")
        let url = try #require(WebIconFontLoader.url(for: source, profile: profile()))
        let corruptData = Data("font:Arkham:ps=corrupt:glyphs=41".utf8)
        let corruptKey = WebIconFontCacheKey(
            url: url, etag: nil, lastModified: nil, data: corruptData
        )
        try cache.store(data: corruptData, key: corruptKey)
        try Data(corruptData.dropLast()).write(
            to: payloadURL(root: root, key: corruptKey),
            options: [.atomic]
        )
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: FakeWebIconFontTransport.syntheticFontData(
                    family: .arkham,
                    postScriptName: "redownloaded-arkham"
                )),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )

        let report = try await loader.loadFonts(for: profile())

        #expect(
            report.availability.registrations[.arkham]?.postScriptName == "redownloaded-arkham"
        )
        #expect(await transport.requests(for: "/fonts/arkham.ttf").count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: payloadURL(root: root, key: corruptKey).path
        ))
    }

    @Test("URLSession transport enforces the streaming font size cap")
    func urlSessionTransportEnforcesStreamingSizeCap() async throws {
        let url = try #require(URL(string: "https://font-stream.test/too-large.ttf"))
        WebIconFontURLProtocol.register(
            url,
            statusCode: 200,
            data: Data(repeating: 0x41, count: WebIconFontLoader.maxFontBytes + 1)
        )
        let transport = URLSessionWebIconFontTransport(
            configuration: urlProtocolConfiguration(),
            timeout: 5
        )

        await #expect(throws: WebIconFontFailure.tooLarge) {
            _ = try await transport.fetch(
                WebIconFontHTTPRequest(url: url),
                maxBytes: WebIconFontLoader.maxFontBytes
            )
        }
    }

    @Test("URLSession transport returns redirect status before reading the body")
    func urlSessionTransportRefusesRedirectBeforeStreamingBody() async throws {
        let url = try #require(URL(string: "https://font-stream.test/redirect.ttf"))
        WebIconFontURLProtocol.register(
            url,
            statusCode: 302,
            headers: ["Location": "https://other.example.test/font.ttf"],
            data: Data(repeating: 0x41, count: WebIconFontLoader.maxFontBytes + 1)
        )
        let transport = URLSessionWebIconFontTransport(
            configuration: urlProtocolConfiguration(),
            timeout: 5
        )

        let response = try await transport.fetch(WebIconFontHTTPRequest(url: url), maxBytes: 1)

        #expect(response.statusCode == 302)
        #expect(response.data.isEmpty)
    }

    @Test("Loader rejects a wrong-identity CoreText font and falls back")
    func loaderRejectsWrongPostScriptIdentity() async throws {
        let wrongFontData = try systemFontData(postScriptName: "ArialRoundedMTBold")
        let transport = FakeWebIconFontTransport(
            responses: [
                "/fonts/arkham.ttf": .success(data: wrongFontData),
            ],
            defaultResponse: .failure(.unexpectedStatus(404))
        )
        let loader = WebIconFontLoader(
            transport: transport,
            registrar: CoreTextWebIconFontRegistrar()
        )

        let report = try await loader.loadFonts(for: profile())

        #expect(report.failures[.arkham] == .invalidFont)
        #expect(!report.loadedFamilies.contains(.arkham))
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .skill(.willpower),
                iconFonts: report.availability
            ) == .systemImage(name: "brain.head.profile")
        )
    }

    @Test("CoreText registrar maps bad font bytes to invalidFont")
    func coreTextRegistrarRejectsBadBytes() throws {
        let registrar = CoreTextWebIconFontRegistrar()
        #expect(throws: WebIconFontFailure.invalidFont) {
            try registrar.validateAndRegister(
                Data("not a font".utf8),
                expectedFamily: .arkham,
                requiredGlyphs: StoryIconGlyph.all.filter { $0.family == .arkham }
            )
        }
    }

    private func memoryRevalidationScript(
        oldData: Data,
        newData: Data
    ) -> [String: [FakeWebIconFontTransport.Response]] {
        Dictionary(uniqueKeysWithValues: WebIconFontSources.required.map { source in
            let initialData = source.family == .arkham
                ? oldData
                : FakeWebIconFontTransport.syntheticFontData(family: source.family)
            let initialETag = source.family == .arkham
                ? "\"old-memory\""
                : "\"\(source.family.rawValue)-memory\""
            let revalidation: FakeWebIconFontTransport.Response = source.family == .arkham
                ? .success(data: newData, etag: "\"new-memory\"")
                : .success(data: Data(), status: 304)
            return (
                source.path,
                [
                    .success(data: initialData, etag: initialETag),
                    revalidation,
                ]
            )
        })
    }

    private func waitForTotalFetchCount(
        _ count: Int,
        transport: FakeWebIconFontTransport
    ) async {
        for _ in 0 ..< 100 {
            if await transport.totalFetchCount() >= count {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func urlProtocolConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebIconFontURLProtocol.self]
        return configuration
    }

    private func systemFontData(postScriptName: String) throws -> Data {
        let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else {
            throw FontFixtureError.unavailable(postScriptName)
        }
        let descriptor = CTFontCopyFontDescriptor(font)
        guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
        else { throw FontFixtureError.unavailable(postScriptName) }
        return try Data(contentsOf: url)
    }

    private func profile() throws -> ServerProfile {
        try ServerProfile.custom(displayName: "Test", rawURL: "https://game.example.test")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func payloadURL(root: URL, key: WebIconFontCacheKey) -> URL {
        root.appendingPathComponent(
            SHA256Hex.digest(key.urlString + "\n" + key.validator) + ".font"
        )
    }
}

private enum FontFixtureError: Error {
    case unavailable(String)
}

private enum SHA256Hex {
    static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class WebIconFontURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var responses: [URL: Response] = [:]
    static func register(
        _ url: URL,
        statusCode: Int,
        headers: [String: String] = [:],
        data: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = Response(statusCode: statusCode, headers: headers, data: data)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return responses[url] != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.response(for: url),
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: response.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func response(for url: URL) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        return responses[url]
    }
}

private actor GatedWebIconFontTransport: WebIconFontTransporting {
    private let gatedPath: String
    private var continuations: [CheckedContinuation<WebIconFontHTTPResponse, any Error>] = []
    private var pendingWaiters: [(
        threshold: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(gatedPath: String = "/fonts/arkham.ttf") {
        self.gatedPath = gatedPath
    }

    func fetch(
        _ request: WebIconFontHTTPRequest,
        maxBytes _: Int
    ) async throws -> WebIconFontHTTPResponse {
        guard request.url.path == gatedPath else { throw WebIconFontFailure.unexpectedStatus(404) }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            notifyWaiters()
        }
    }

    func waitUntilPending(_ count: Int) async {
        if continuations.count >= count {
            return
        }
        await withCheckedContinuation { pendingWaiters.append((count, $0)) }
    }

    func resumeOldest(with response: WebIconFontHTTPResponse) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: response)
    }

    private func notifyWaiters() {
        pendingWaiters.removeAll { entry in
            guard continuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }
}

private struct PrefixWebIconFontRegistrar: WebIconFontRegistering {
    func validateAndRegister(
        _ data: Data,
        expectedFamily: WebIconFontFamily,
        requiredGlyphs: [StoryIconGlyph]
    ) throws -> WebIconFontRegistration {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw WebIconFontFailure.invalidFont
        }
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "font",
              parts[1] == Substring(expectedFamily.rawValue),
              parts[2].hasPrefix("ps="),
              parts[3].hasPrefix("glyphs=")
        else { throw WebIconFontFailure.invalidFont }
        let postScriptName = String(parts[2].dropFirst(3))
        let scalars = Set(parts[3].dropFirst(7).split(separator: ",").compactMap { value in
            UInt32(value, radix: 16)
        })
        let required = Set(requiredGlyphs.map(\.scalar.value))
        guard !postScriptName.isEmpty, !scalars.isDisjoint(with: required) else {
            throw WebIconFontFailure.invalidFont
        }
        return WebIconFontRegistration(
            family: expectedFamily,
            postScriptName: postScriptName,
            supportedScalars: scalars
        )
    }
}

private actor FakeWebIconFontTransport: WebIconFontTransporting {
    enum Response: Sendable {
        case success(
            data: Data,
            etag: String? = nil,
            lastModified: String? = nil,
            status: Int = 200
        )
        case failure(WebIconFontFailure)
    }

    private var responses: [String: [Response]]
    private let defaultResponse: Response
    private var fetchCounts: [String: Int] = [:]
    private var capturedRequests: [WebIconFontHTTPRequest] = []

    init(
        responses: [String: Response],
        defaultResponse: Response = .failure(.unexpectedStatus(404))
    ) {
        self.responses = responses.mapValues { [$0] }
        self.defaultResponse = defaultResponse
    }

    init(
        scriptedResponses: [String: [Response]],
        defaultResponse: Response = .failure(.unexpectedStatus(404))
    ) {
        responses = scriptedResponses
        self.defaultResponse = defaultResponse
    }

    func fetch(
        _ request: WebIconFontHTTPRequest,
        maxBytes: Int
    ) async throws -> WebIconFontHTTPResponse {
        capturedRequests.append(request)
        let path = request.url.path
        fetchCounts[path, default: 0] += 1
        let response = popResponse(for: path)
        switch response {
        case let .success(data, etag, lastModified, status):
            guard status != 200 || data.count <= maxBytes else { throw WebIconFontFailure.tooLarge }
            return WebIconFontHTTPResponse(
                statusCode: status, etag: etag, lastModified: lastModified, data: data
            )
        case let .failure(failure):
            throw failure
        }
    }

    private func popResponse(for path: String) -> Response {
        guard var queue = responses[path], !queue.isEmpty else { return defaultResponse }
        let response = queue.removeFirst()
        responses[path] = queue
        return response
    }

    func totalFetchCount() -> Int {
        fetchCounts.values.reduce(0, +)
    }

    func requests(for path: String) -> [WebIconFontHTTPRequest] {
        capturedRequests.filter { $0.url.path == path }
    }

    static func validFonts() -> FakeWebIconFontTransport {
        FakeWebIconFontTransport(responses: validFontResponses())
    }

    static func validFontResponses() -> [String: Response] {
        Dictionary(uniqueKeysWithValues: WebIconFontSources.required.map { source in
            (source.path, Response.success(
                data: syntheticFontData(family: source.family),
                etag: "\"\(source.family.rawValue)\""
            ))
        })
    }

    static func syntheticFontData(
        family: WebIconFontFamily,
        postScriptName: String? = nil,
        excluding excludedIconNames: Set<String> = []
    ) -> Data {
        let glyphs = StoryIconGlyph.all
            .filter { $0.family == family && !excludedIconNames.contains($0.iconName) }
            .map { String(format: "%04X", $0.scalar.value) }
            .joined(separator: ",")
        let postScriptName = postScriptName ?? family.expectedPostScriptName
        return Data(
            "font:\(family.rawValue):ps=\(postScriptName):glyphs=\(glyphs)".utf8
        )
    }
}
