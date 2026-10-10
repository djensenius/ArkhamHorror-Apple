@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog fixture provenance")
struct LocaleCatalogFixtureProvenanceTests {
    private let expectedDigests = [
        "Contract/capabilities-locale-catalog.json":
            "d9b61ece46e8bd7416f9c5cd1d7c16b9f84daaf09b898125e8892d44afb7d036",
        "Contract/locale-catalog-backend-registry.json":
            "dd5499efa098c6b99492115fc06f55bc21b8d46d4434f9b5fa94bb1aa104180e",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448.json":
            "2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488.json":
            "309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-9a30c62c45fb06a929d13506b454d5b9637c5bf3eeb986243ddb007a856cb1a5.json":
            "9a30c62c45fb06a929d13506b454d5b9637c5bf3eeb986243ddb007a856cb1a5",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693.json":
            "d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693",
        "Contract/locale-catalog-manifest.json":
            "604f6619514e7562f8070977038a3a67fa9b0dc13f22200fb3603d3dc436118d",
        "Contract/locale-catalog-owned-files.json":
            "13924d3a1d159fabdd0aaf65a3701da379d8641fb9164089463e6281ddef6e6c",
        "Contract/locale-catalog-source-de.json":
            "1d60ade53a4b4d7241c88ce8f0cab1b4027e81cd25f10f1ad815948e198fd0bb",
        "Contract/locale-catalog-source-en.json":
            "879de3d794fa5da6202243d3c2b5a37f7e59f7e2582affc4c94d5e9ebb4ff2dd",
        "Contract/locale-catalog-source-pt-BR.json":
            "cd7593ead3708918f8d8df4dea9775659a78351d90c485f3c82ad8fe69f4f241",
        "Contract/manifest.json":
            "a91257aefcab09ab3c5614edcbe0e4631a28d40f286cb8a55ea2c4d8d4a735f2",
        "Schemas/capabilities.schema.json":
            "a71638283a94b4e68c29c1a705dba0f007a3b5a28de324fecdcfdbd179430658",
        "Schemas/chunk.schema.json":
            "b96fbca81f638e57e7f1a7f9eb47b9968c4a608da42187998b0ca6eb32647584",
        "Schemas/manifest.schema.json":
            "1030f4fec1f96b7401a8ebb2cea50a92dc97f0334d9b24f992f00fa47080762d",
    ]

    private func fixture(_ path: String) throws -> Data {
        let components = path.split(separator: "/", maxSplits: 1).map(String.init)
        let url = try #require(
            Bundle.module.url(
                forResource: components[1].replacingOccurrences(of: ".json", with: ""),
                withExtension: "json",
                subdirectory: "Fixtures/LocaleCatalog/\(components[0])"
            )
        )
        return try Data(contentsOf: url)
    }

    private func vendoredSnapshot(
        preferredLanguages: [String]
    ) async throws -> LocaleCatalogSnapshot {
        let capabilities = try ContractJSON.decode(
            ServerCapabilities.self,
            from: fixture("Contract/capabilities-locale-catalog.json")
        )
        let advertisement = try #require(capabilities.localeCatalog)
        let profile = try ServerProfile.custom(
            displayName: "Vendored locale catalog",
            rawURL: "https://catalog.example.test/profile-prefix"
        )
        let manifestURL = try #require(advertisement.resolvedManifestURL(for: profile))
        let manifestBytes = try fixture("Contract/locale-catalog-manifest.json")
        let manifest = try LocaleCatalogManifest.validate(
            LosslessJSONParser.parse(manifestBytes),
            against: advertisement
        ).get()
        var responses = [
            manifestURL: localeCatalogResponse(data: manifestBytes, url: manifestURL),
        ]
        for locale in manifest.locales {
            for descriptor in locale.chunks {
                let chunkURL = try #require(
                    advertisement.resolvedChunkURL(path: descriptor.path, for: profile)
                )
                let chunkBytes = try fixture(
                    "Contract/locale-catalog-chunk-\(descriptor.sha256).json"
                )
                responses[chunkURL] = localeCatalogResponse(data: chunkBytes, url: chunkURL)
            }
        }
        return try await LocaleCatalogLoader(
            transport: FixtureLocaleCatalogTransport(responses: responses)
        ).load(
            advertisement: advertisement,
            profile: profile,
            preferredLanguages: preferredLanguages
        ).get()
    }

    private func localeCatalogResponse(data: Data, url: URL) -> LocaleCatalogResponse {
        LocaleCatalogResponse(
            statusCode: 200,
            contentType: "application/json; charset=utf-8",
            contentTypeOptions: "nosniff",
            url: url,
            data: data
        )
    }

    @Test("Every checked-in artifact has its governed SHA-256")
    func artifactsHaveExpectedDigests() throws {
        for (path, digest) in expectedDigests {
            #expect(try LocaleCatalogLoader.sha256Hex(fixture(path)) == digest)
        }
    }

    @Test("Vendored addToken icon variable renders as the elder thing glyph")
    func vendoredAddTokenIconVariableRenders() async throws {
        let snapshot = try await vendoredSnapshot(preferredLanguages: ["en"])
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let nodes = try resolver.render(
            key: "addToken", variables: .object(["token": .string("elderThing")])
        ).get()
        #expect(nodes == [.text("core.addToken.en."), .semanticIcon(.chaosToken(.elderThing))])
        #expect(nodes.map(\.plainText).joined() == "core.addToken.en.elder thing")
    }

    @Test("The capability, manifest, and chunks satisfy the v1 closure")
    func catalogIsInternallyConsistent() throws {
        let capabilities = try ContractJSON.decode(
            ServerCapabilities.self,
            from: fixture("Contract/capabilities-locale-catalog.json")
        )
        let advertisement = try #require(capabilities.localeCatalog)
        let manifestBytes = try fixture("Contract/locale-catalog-manifest.json")
        #expect(LocaleCatalogLoader.sha256Hex(manifestBytes) == advertisement.manifestSha256)
        let manifest = try LocaleCatalogManifest.validate(
            LosslessJSONParser.parse(manifestBytes),
            against: advertisement
        ).get()
        for locale in manifest.locales {
            for descriptor in locale.chunks {
                let data = try fixture("Contract/locale-catalog-chunk-\(descriptor.sha256).json")
                #expect(data.count == descriptor.bytes)
                #expect(LocaleCatalogLoader.sha256Hex(data) == descriptor.sha256)
                let result = try LocaleCatalogChunk.validate(
                    LosslessJSONParser.parse(data),
                    expectedLocale: locale.locale,
                    expectedFallback: locale.fallback,
                    expectedPack: descriptor.pack,
                    expectedKeys: descriptor.keys,
                    expectedUnsupportedKeys: descriptor.unsupportedKeys
                )
                if case .failure = result {
                    Issue.record("catalog chunk \(descriptor.sha256) failed validation")
                }
            }
        }
    }
}
