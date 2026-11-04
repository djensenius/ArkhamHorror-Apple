@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog fixture provenance")
struct LocaleCatalogFixtureProvenanceTests {
    private let expectedDigests = [
        "Contract/capabilities-locale-catalog.json":
            "7d6d3f581a2358d6a8028018183957fc6f5e7c84f38bc69d1749fcc288157eb9",
        "Contract/locale-catalog-backend-registry.json":
            "8a3bd549d7553a248a9b8c5996c811183060ce823d8b1ad391b5006d6886b642",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-0aa7e0e3622e1963b538fcb506184809a9f3caffea917e97d7b78098c277f1f1.json":
            "0aa7e0e3622e1963b538fcb506184809a9f3caffea917e97d7b78098c277f1f1",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-0d670d111cf4f1a3b23c24db076fb2d687383ff9f29043295bd50aa907992746.json":
            "0d670d111cf4f1a3b23c24db076fb2d687383ff9f29043295bd50aa907992746",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448.json":
            "2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488.json":
            "309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-97c056d4405e800061cff060f996eff82dde0f84fb396321448bd4e58e6a3640.json":
            "97c056d4405e800061cff060f996eff82dde0f84fb396321448bd4e58e6a3640",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-9a30c62c45fb06a929d13506b454d5b9637c5bf3eeb986243ddb007a856cb1a5.json":
            "9a30c62c45fb06a929d13506b454d5b9637c5bf3eeb986243ddb007a856cb1a5",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693.json":
            "d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693",
        "Contract/locale-catalog-manifest.json":
            "6cf596192d97f4c7f40e3cfa51da04ce8fbec211dce1eac6875654348c6687fe",
        "Contract/locale-catalog-owned-files.json":
            "7c129ffb77c646515bc2b721f8938dbad21f02cec2a5ffa3c4f6c0708e702191",
        "Contract/locale-catalog-source-de.json":
            "db5a6b0626844d9e3a9b575d2916f721bfde2afe7d27c9e78ec542f893def86d",
        "Contract/locale-catalog-source-en.json":
            "0b66ca261b697a4fd3cb8375c694562730d3d02678efcaad2fed46db0eb6afed",
        "Contract/locale-catalog-source-pl.json":
            "5ac380c4d12470b9f8357dccbab9df599d26adb8fac27ed35a242357e504e195",
        "Contract/locale-catalog-source-pt-BR.json":
            "cd7593ead3708918f8d8df4dea9775659a78351d90c485f3c82ad8fe69f4f241",
        "Contract/manifest.json":
            "9d5d4a40296a4e5b3c88c7ebfdc3eb0be8214c682ad97a4f26af2afc07178232",
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
