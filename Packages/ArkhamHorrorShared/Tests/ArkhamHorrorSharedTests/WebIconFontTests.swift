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

    private func profile() throws -> ServerProfile {
        try ServerProfile.custom(displayName: "Test", rawURL: "https://game.example.test")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

private extension WebIconFontFamily {
    var syntheticPostScriptName: String {
        switch self {
        case .arkham: "AHLCG"
        case .arkhamIcons: "arkhamicons"
        case .arkhamSlim: "arkhamslim"
        case .icons: "icon"
        }
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
                data: syntheticFontData(family: source.family),
                etag: "\"\(source.family.rawValue)\""
            ))
        })
    }

    static func syntheticFontData(
        family: WebIconFontFamily,
        excluding excludedIconNames: Set<String> = []
    ) -> Data {
        let glyphs = StoryIconGlyph.all
            .filter { $0.family == family && !excludedIconNames.contains($0.iconName) }
            .map { String(format: "%04X", $0.scalar.value) }
            .joined(separator: ",")
        return Data(
            "font:\(family.rawValue):ps=\(family.syntheticPostScriptName):glyphs=\(glyphs)".utf8
        )
    }
}
