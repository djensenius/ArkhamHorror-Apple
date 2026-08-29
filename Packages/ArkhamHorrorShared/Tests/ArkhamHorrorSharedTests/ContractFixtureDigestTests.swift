@testable import ArkhamHorrorShared
import CryptoKit
import Foundation
import Testing

@Suite("ContractFixtureDigest")
struct ContractFixtureDigestTests {
    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test("Every registered digest matches the bundled fixture's actual SHA-256")
    func everyDigestMatchesBundledBytes() throws {
        for entry in ContractFixtureDigests.all {
            let data = try fixtureData(named: entry.fileName)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            #expect(
                hex == entry.sha256Hex,
                "Fixture '\(entry.fileName).json' has drifted from its pinned SHA-256 digest"
            )
        }
    }

    @Test("The digest table covers manifest, capabilities, and all four contract fixtures")
    func tableCoversExpectedFiles() {
        let fileNames = Set(ContractFixtureDigests.all.map(\.fileName))
        #expect(fileNames == [
            "manifest", "capabilities", "catalog", "decks", "game-lifecycle", "game-list",
        ])
    }

    @Test("The vendored manifest's schemaRevision matches ContractPin.current exactly")
    func manifestSchemaRevisionMatchesPin() throws {
        struct ManifestFixture: Decodable {
            let schemaRevision: ContractRevision
        }
        let data = try fixtureData(named: "manifest")
        let manifest = try JSONDecoder().decode(ManifestFixture.self, from: data)
        #expect(manifest.schemaRevision == ContractPin.current.supportedSchemaRevision)
    }

    @Test("ContractPin.current is pinned to the documented backend commit")
    func pinnedToDocumentedCommit() {
        #expect(ContractPin.current.backendCommit == "6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27")
    }
}
