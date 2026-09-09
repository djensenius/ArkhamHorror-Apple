@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog fixture provenance")
struct LocaleCatalogFixtureProvenanceTests {
    private let expectedDigests = [
        "Contract/capabilities-locale-catalog.json":
            "e443e95294b8a8f1b2d7324564c3e827caeb0a4b8c8073b13e062849149edada",
        "Contract/locale-catalog-backend-registry.json":
            "3f39e0f443341bc194a2ba645584007a161875d2e1981bb9c16c8f466880c6c4",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693.json":
            "d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448.json":
            "2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488.json":
            "309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488",
        // swiftlint:disable:next line_length
        "Contract/locale-catalog-chunk-932fbfdd3570550d2bd7255599e7b54cb8ceac12d4597686613d97254b67c12d.json":
            "932fbfdd3570550d2bd7255599e7b54cb8ceac12d4597686613d97254b67c12d",
        "Contract/locale-catalog-manifest.json":
            "58712088a3d5ca2aa0903a6867d9d224c8b33e0606cb1a96fbd021b69528aa1e",
        "Contract/locale-catalog-source-de.json":
            "1d60ade53a4b4d7241c88ce8f0cab1b4027e81cd25f10f1ad815948e198fd0bb",
        "Contract/locale-catalog-source-en.json":
            "deeb7057a50a687039efdb42bb1484b0d67afb9c73ee670a39c67485f94e2a19",
        "Contract/locale-catalog-source-pt-BR.json":
            "cd7593ead3708918f8d8df4dea9775659a78351d90c485f3c82ad8fe69f4f241",
        "Contract/manifest.json":
            "165542045b90c8a9b01061917a4d661af405ff0f380919ee83eea0737da9bc89",
        "Schemas/capabilities.schema.json":
            "7cc6d2805a47ee19549beab91f3c54085f2726b8d0671f0a3ae662bab820d42a",
        "Schemas/chunk.schema.json":
            "545e12548f904617e6cc9143ac6da4d6181f11bf727bdac8856007316b19ed9b",
        "Schemas/manifest.schema.json":
            "733d8ff1cde160c9a386477a426fa46c38d90b20c693842899ada297419b43a9",
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

    @Test("Every checked-in artifact has its governed SHA-256")
    func artifactsHaveExpectedDigests() throws {
        for (path, digest) in expectedDigests {
            #expect(try LocaleCatalogLoader.sha256Hex(fixture(path)) == digest)
        }
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
