@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Story asset source settings")
struct StoryAssetSourceLoaderTests {
    private func load(
        _ body: String, status: Int = 200, contentType: String = "application/json",
        contentTypeOptions: String? = "nosniff", redirected: Bool = false
    ) async throws -> AssetSourceNamespace {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let url = documents.profile.endpointURL(path: "/site-settings")
        let response = documents.response(
            data: Data(body.utf8), status: status, contentType: contentType,
            contentTypeOptions: contentTypeOptions,
            url: redirected ? URL(string: "https://evil.test/site-settings") : url
        )
        let transport = FixtureLocaleCatalogTransport(responses: [url: response])
        let source = try await StoryAssetSourceLoader(transport: transport)
            .load(for: documents.profile)
        #expect(await transport.requests == [url])
        #expect(url
            .absoluteString == "https://catalog.example.test/profile-prefix/api/v1/site-settings")
        return source
    }

    @Test("The selected server authorizes a separate asset host and exact deployment prefix")
    func selectedHost() async throws {
        let source = try await load(#"{"assetHost":"https://cdn.example.test:8443/assets"}"#)
        #expect(try source ==
            AssetSourceNamespace(rawAssetBase: "https://cdn.example.test:8443/assets"))
        let reference = StoryAssetReference(
            role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: nil, source: source
        )
        let key = try #require(reference.assetKey)
        let candidate = try #require(AssetLocator.candidates(for: key).first)
        let expectedURL = "https://cdn.example.test:8443/assets"
            + "/img/arkham/encounter-sets/rats.png"
        #expect(candidate.url(base: source).absoluteString == expectedURL)
    }

    @Test("Null or absent settings select the web default, but empty means server-origin root")
    func webDefaults() async throws {
        #expect(try await load(#"{"assetHost":null}"#) == .hosted)
        #expect(try await load("{}") == .hosted)
        let source = try await load(#"{"assetHost":""}"#)
        #expect(try source == AssetSourceNamespace(rawAssetBase: "https://catalog.example.test"))
        #expect(source.basePath.isEmpty)
        #expect(try await load(#"{"assetHost":"http://127.0.0.1:8080"}"#) ==
            AssetSourceNamespace(rawAssetBase: "http://127.0.0.1:8080"))
    }

    @Test("Settings reuse the JSON media-type grammar without requiring catalog-only nosniff")
    func responseTypePolicy() async throws {
        #expect(try await load(
            "{}", contentType: "application/vnd.arkham.settings+json",
            contentTypeOptions: nil
        ) == .hosted)
        #expect(try await load("{}", contentTypeOptions: nil) == .hosted)
        #expect(try await load("{}", contentTypeOptions: "no-sniff") == .hosted)
    }

    @Test("Unsafe settings never fall back to a success CDN", arguments: [
        "http://remote.example.test", "https://user:secret@cdn.example.test",
        "https://cdn.example.test/?next=evil", "https://cdn.example.test/#fragment",
        "https://cdn.example.test/../private", "https://cdn.example.test/%2e%2e/private",
        "https://%65vil.test", "http://127。0。0。1:8080",
        "//cdn.example.test", "/assets", "cdn.example.test", "file:///private",
        "javascript:alert(1)",
    ])
    func unsafeSettings(_ raw: String) async throws {
        let data = try JSONEncoder().encode(["assetHost": raw])
        let text = try #require(String(data: data, encoding: .utf8))
        await #expect(throws: LocaleCatalogFailure.untrustedAssetSource) {
            try await load(text)
        }
    }

    @Test("Settings errors, redirect substitution, oversized bodies and duplicate keys fail closed")
    func rejectsResponses() async throws {
        await #expect(throws: LocaleCatalogFailure.untrustedAssetSource) {
            try await load(#"{"assetHost":42}"#)
        }
        await #expect(throws: LocaleCatalogFailure.malformedJSON) {
            try await load(#"{"assetHost":null,"assetHost":"https://evil.test"}"#)
        }
        await #expect(throws: LocaleCatalogFailure.redirected) {
            try await load("{}", redirected: true)
        }
        await #expect(throws: LocaleCatalogFailure.unexpectedStatus(503)) {
            try await load("{}", status: 503)
        }
        await #expect(throws: LocaleCatalogFailure.unacceptableContentType) {
            try await load("{}", contentType: "text/html")
        }
        await #expect(throws: LocaleCatalogFailure.tooLarge) {
            try await load(String(repeating: " ", count: 16385))
        }
    }

    @Test("Failures shared with image settings use neutral story-content announcements")
    func sharedFailureAnnouncements() {
        let failures: [LocaleCatalogFailure] = [
            .redirected, .unexpectedStatus(503), .unacceptableContentType, .tooLarge,
            .transportFailure, .malformedJSON,
        ]
        for failure in failures {
            #expect(failure.announcement.contains("story content"))
            #expect(!failure.announcement.contains("story text"))
        }
    }

    @Test("Cancelling the settings request never authorizes an asset source")
    func cancellation() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let transport = FixtureLocaleCatalogTransport(responses: [:], cancellationRequestNumber: 1)
        await #expect(throws: CancellationError.self) {
            try await StoryAssetSourceLoader(transport: transport).load(for: documents.profile)
        }
    }
}
