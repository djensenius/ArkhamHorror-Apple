@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog fixture provenance")
struct LocaleCatalogFixtureProvenanceTests {
    private let expectedDigests = [
        "Contract/capabilities-locale-catalog.json":
            "599caed7b93ced2677384660b8f6bd73448d1009e591c0fe9326533394f0f340",
        "Contract/locale-catalog-backend-registry.json":
            "bbd3861cf7bc182dc601d276c39b48b608a60f36ce1d04aca7c4c5f378dfbbc8",
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
        "Contract/locale-catalog-chunk-53afdb521d26506a1661e54f71d31fc3828ad5d9badd6ebac62b68bc6a554c48.json":
            "53afdb521d26506a1661e54f71d31fc3828ad5d9badd6ebac62b68bc6a554c48",
        "Contract/locale-catalog-manifest.json":
            "c4e04ad93890c27c1b8041f7c15fc74ddcc0ece7cf4e5ede6dd3a5e5580d1937",
        "Contract/locale-catalog-source-de.json":
            "1d60ade53a4b4d7241c88ce8f0cab1b4027e81cd25f10f1ad815948e198fd0bb",
        "Contract/locale-catalog-source-en.json":
            "03306c293a590a2c75f31571e2a042f1c22981129b5d2b2a21a64eebed986363",
        "Contract/locale-catalog-source-pt-BR.json":
            "cd7593ead3708918f8d8df4dea9775659a78351d90c485f3c82ad8fe69f4f241",
        "Contract/manifest.json":
            "ef832ddbce141bc13d92bad82c8a05113e302cebfcf78d61381e6d8778b0ab01",
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
