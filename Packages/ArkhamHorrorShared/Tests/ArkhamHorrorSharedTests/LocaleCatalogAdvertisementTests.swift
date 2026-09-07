@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog advertisement")
struct LocaleCatalogAdvertisementTests {
    private func capabilities(_ suffix: String) -> Data {
        Data(
            """
            {"schemaRevision":"0.1.23","status":"baseline-incomplete","apiBasePath":"/api/v1",\
            "nativeClientMinimumRevision":"0.1.0","capabilities":\(suffix)}
            """.utf8
        )
    }

    @Test("Catalog advertisement requires both the capability and the closed object")
    func catalogAdvertisementRequiresBidirectionalPairing() throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let object = """
        ,"localeCatalog":{"manifestUrl":"/locale-catalog/manifest.json",\
        "catalogRevision":"\(documents.advertisement.catalogRevision)","schemaVersion":"1.0.0",\
        "defaultLocale":"en","supportedLocales":["en"],\
        "manifestSha256":"\(documents.advertisement.manifestSha256)"}
        """
        let valid = capabilities(
            "[\"future.capability\",\"i18n.locale-catalog.v1\"]\(object)"
        )
        let decoded = try ContractJSON.decode(ServerCapabilities.self, from: valid)
        #expect(decoded.capabilities.contains("future.capability"))
        #expect(decoded.localeCatalog == documents.advertisement)

        let withoutCapability = try ContractJSON.decode(
            ServerCapabilities.self, from: capabilities("[]\(object)")
        )
        #expect(withoutCapability.localeCatalog == nil)
        let withoutObject = try ContractJSON.decode(
            ServerCapabilities.self,
            from: capabilities("[\"i18n.locale-catalog.v1\"]")
        )
        #expect(withoutObject.localeCatalog == nil)
    }

    @Test("A valid 0.1.22 response carries no catalog authority despite the paired additive fields")
    func preGovernanceResponseDoesNotAuthorizeCatalog() throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let response = Data(
            """
            {"schemaRevision":"0.1.22","status":"baseline-incomplete","apiBasePath":"/api/v1",\
            "nativeClientMinimumRevision":"0.1.0",\
            "capabilities":["i18n.locale-catalog.v1"],\
            "localeCatalog":{"manifestUrl":"/locale-catalog/manifest.json",\
            "catalogRevision":"\(documents.advertisement.catalogRevision)","schemaVersion":"1.0.0",\
            "defaultLocale":"en","supportedLocales":["en"],\
            "manifestSha256":"\(documents.advertisement.manifestSha256)"}}
            """.utf8
        )
        let capabilities = try ContractJSON.decode(ServerCapabilities.self, from: response)
        let historicalPin = ContractPin(
            backendCommit: "historical-test-pin",
            supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 22),
            minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 22),
            expectedApiBasePath: "/api/v1",
            sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
        )
        #expect(CompatibilityEvaluator(pin: historicalPin).evaluate(capabilities) == .compatible(
            capabilities: [LocaleCatalogLimits.capabilityIdentifier],
            localeCatalog: nil
        ))
    }

    @Test("Manifest URL grammar rejects noncanonical and unsafe paths")
    func manifestURLGrammarRejectsUnsafeInput() {
        let rejected = [
            "locale-catalog/manifest.json",
            "//other.example.test/catalog.json",
            "/locale-catalog/../manifest.json",
            "/locale-catalog/manifest.json?query",
            "http://catalog.example.test/manifest.json",
            "https://Catalog.example.test/manifest.json",
            "https://127.1/manifest.json",
            "https://catalog.example.test:443/manifest.json",
            "https://catalog.example.test/catalog.json\n",
        ]
        for input in rejected {
            #expect(LocaleCatalogManifestURL.parse(input) == nil, "unexpectedly accepted \(input)")
        }
    }

    @Test("Root-relative and split-host URLs preserve the advertised authority")
    func manifestURLResolutionPreservesAuthority() throws {
        let profile = try ServerProfile.custom(
            displayName: "Prefixed",
            rawURL: "https://profile.example.test/prefix"
        )
        let relative = try #require(
            LocaleCatalogManifestURL.parse("/locale-catalog/manifest.json")
        )
        let relativeAdvertisement = LocaleCatalogAdvertisement(
            manifestURL: relative,
            catalogRevision: "1.0123456789abcdef0123456789abcdef",
            schemaVersion: "1.0.0",
            defaultLocale: "en",
            supportedLocales: ["en"],
            manifestSha256: SyntheticLocaleCatalogDocuments.hex
        )
        #expect(
            relativeAdvertisement.resolvedManifestURL(for: profile)?.absoluteString
                == "https://profile.example.test/locale-catalog/manifest.json"
        )

        let absolute = try #require(
            LocaleCatalogManifestURL.parse("https://static.example.test/catalog/manifest.json")
        )
        let absoluteAdvertisement = LocaleCatalogAdvertisement(
            manifestURL: absolute,
            catalogRevision: relativeAdvertisement.catalogRevision,
            schemaVersion: "1.0.0",
            defaultLocale: "en",
            supportedLocales: ["en"],
            manifestSha256: SyntheticLocaleCatalogDocuments.hex
        )
        #expect(
            absoluteAdvertisement.resolvedManifestURL(for: profile)?.absoluteString
                == "https://static.example.test/catalog/manifest.json"
        )
    }

    @Test("Language-resolution keys reject ASCII-normalized collisions")
    func languageResolutionRejectsNormalizedCollisions() throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let original = try #require(String(bytes: documents.manifestBytes, encoding: .utf8))
        let replaced = original.replacingOccurrences(
            of: #""languageResolution":[{"tag":"en","locale":"en"}]"#,
            with: #""languageResolution":[{"tag":"fr","locale":"en"},{"tag":"FR","locale":"en"}]"#
        )
        let value = try LosslessJSONParser.parse(Data(replaced.utf8))
        #expect(LocaleCatalogManifest.validate(
            value, against: documents.advertisement
        ) == .failure(.malformedManifest))
    }

    @Test("Manifest count aggregation rejects integer overflow instead of trapping")
    func manifestCountOverflowFailsClosed() throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let original = try #require(String(bytes: documents.manifestBytes, encoding: .utf8))
        let digest = LocaleCatalogLoader.sha256Hex(documents.chunkBytes)
        let replacement = """
        "chunks":[{"pack":"story","path":"/locale-catalog/c/\(digest).json",\
        "bytes":1,"sha256":"\(digest)","keys":\(Int.max),"unsupportedKeys":0},\
        {"pack":"other","path":"/locale-catalog/c/\(SyntheticLocaleCatalogDocuments.hex).json",\
        "bytes":1,"sha256":"\(SyntheticLocaleCatalogDocuments.hex)",\
        "keys":\(Int.max),"unsupportedKeys":0}],"keys":0,"bytes":2
        """
        let originalRecord = """
        "chunks":[{"pack":"story","path":"/locale-catalog/c/\(digest).json",\
        "bytes":\(documents.chunkBytes.count),"sha256":"\(digest)",\
        "keys":1,"unsupportedKeys":0}],"keys":1,"bytes":\(documents.chunkBytes.count)
        """
        let mutated = original.replacingOccurrences(of: originalRecord, with: replacement)
        #expect(mutated != original)
        let value = try LosslessJSONParser.parse(Data(mutated.utf8))
        #expect(LocaleCatalogManifest.validate(
            value, against: documents.advertisement
        ) == .failure(.malformedManifest))
    }
}
