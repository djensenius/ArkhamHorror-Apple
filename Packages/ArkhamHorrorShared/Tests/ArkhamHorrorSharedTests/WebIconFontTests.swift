@testable import ArkhamHorrorShared
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
        let actual = StoryIconGlyph.all.map(WebIconFontFixtureMapping.init(glyph:))
        #expect(actual == fixture.mappings)
    }

    @Test("Renderer uses registered web glyphs and falls back per family")
    func rendererUsesGlyphsWhenFamilyLoadedAndSystemFallbackOtherwise() {
        let onlyArkhamIcons = WebIconFontAvailability(loadedFamilies: [.arkhamIcons])
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.skull),
                iconFonts: onlyArkhamIcons
            ) == .webGlyph(iconName: "skull", family: .arkhamIcons, glyph: "\u{E910}")
        )
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.blood),
                iconFonts: onlyArkhamIcons
            ) == .systemImage(name: "circle.hexagongrid.fill")
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

    @Test("Loader serves a disk cache hit without fetching")
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
            responses: [:],
            defaultResponse: .failure(.transportFailure)
        )
        let secondLoader = WebIconFontLoader(
            transport: secondTransport,
            registrar: PrefixWebIconFontRegistrar(),
            diskCache: cache
        )
        let secondReport = try await secondLoader.loadFonts(for: profile())
        #expect(secondReport.loadedFamilies == Set(WebIconFontFamily.allCases))
        #expect(secondReport.failures.isEmpty)
        #expect(await secondTransport.totalFetchCount() == 0)
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
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.skull),
                iconFonts: report.availability
            ) == .webGlyph(iconName: "skull", family: .arkhamIcons, glyph: "\u{E910}")
        )
        #expect(
            StoryInlineTextRenderer.semanticIconRun(
                for: .chaosToken(.blood),
                iconFonts: report.availability
            ) == .systemImage(name: "circle.hexagongrid.fill")
        )
    }

    private func profile() throws -> ServerProfile {
        try ServerProfile.custom(displayName: "Test", rawURL: "https://game.example.test")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct PrefixWebIconFontRegistrar: WebIconFontRegistering {
    func validateAndRegister(_ data: Data, expectedFamily: WebIconFontFamily) throws {
        let expected = "font:\(expectedFamily.rawValue)"
        guard let decoded = String(data: data, encoding: .utf8),
              decoded.hasPrefix(expected)
        else { throw WebIconFontFailure.invalidFont }
    }
}

private actor FakeWebIconFontTransport: WebIconFontTransporting {
    enum Response: Sendable {
        case success(data: Data, etag: String? = nil, status: Int = 200)
        case failure(WebIconFontFailure)
    }

    private var responses: [String: Response]
    private let defaultResponse: Response
    private var fetchCounts: [String: Int] = [:]

    init(
        responses: [String: Response],
        defaultResponse: Response = .failure(.unexpectedStatus(404))
    ) {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    func fetch(_ url: URL, maxBytes: Int) async throws -> WebIconFontHTTPResponse {
        let path = url.path
        fetchCounts[path, default: 0] += 1
        let response = responses[path] ?? defaultResponse
        switch response {
        case let .success(data, etag, status):
            guard data.count <= maxBytes else { throw WebIconFontFailure.tooLarge }
            return WebIconFontHTTPResponse(statusCode: status, etag: etag, data: data)
        case let .failure(failure):
            throw failure
        }
    }

    func totalFetchCount() -> Int {
        fetchCounts.values.reduce(0, +)
    }

    static func validFonts() -> FakeWebIconFontTransport {
        FakeWebIconFontTransport(responses: validFontResponses())
    }

    static func validFontResponses() -> [String: Response] {
        Dictionary(uniqueKeysWithValues: WebIconFontSources.required.map { source in
            (source.path, Response.success(
                data: Data("font:\(source.family.rawValue):test".utf8),
                etag: "\"\(source.family.rawValue)\""
            ))
        })
    }
}
