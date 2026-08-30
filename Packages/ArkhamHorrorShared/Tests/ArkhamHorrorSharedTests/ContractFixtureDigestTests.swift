@testable import ArkhamHorrorShared
import CryptoKit
import Foundation
import Testing

@Suite("ContractFixtureDigest")
struct ContractFixtureDigestTests {
    /// The one subdirectory holding fixtures vendored from `ContractPin.current`'s pinned
    /// backend commit. `token.json`/`whoami.json` (synthetic auth fixtures, unrelated to
    /// the contract pin) live one level up in `Fixtures/`, deliberately outside this
    /// directory so they're never mistaken for a governed contract artifact.
    private static let contractFixturesSubdirectory = "Fixtures/Contract"

    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: Self.contractFixturesSubdirectory
            )
        )
        return try Data(contentsOf: url)
    }

    /// The file names actually bundled under `Fixtures/Contract`, derived from the real
    /// resource listing rather than a second hand-maintained literal. An addition,
    /// removal, or basename substitution in that directory changes this set without any
    /// source edit elsewhere, so comparing it against ``ContractFixtureDigests/all`` below
    /// actually catches drift instead of comparing two copies of the same hardcoded list.
    private func actualBundledFileNames() throws -> Set<String> {
        let urls = try #require(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: Self.contractFixturesSubdirectory
            ),
            "Expected at least one bundled fixture under \(Self.contractFixturesSubdirectory)"
        )
        return Set(urls.map { $0.deletingPathExtension().lastPathComponent })
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

    @Test(
        """
        The digest registry's file-name set exactly matches what's actually bundled under \
        Fixtures/Contract
        """
    )
    func registryExactlyMatchesBundledDirectory() throws {
        let registered = Set(ContractFixtureDigests.all.map(\.fileName))
        let actual = try actualBundledFileNames()
        #expect(
            registered == actual,
            """
            Registry/directory mismatch: registered-only=\(registered.subtracting(actual)), \
            bundled-only=\(actual.subtracting(registered))
            """
        )
    }

    @Test("The digest registry has no duplicate basename")
    func registryHasNoDuplicateBasename() {
        let names = ContractFixtureDigests.all.map(\.fileName)
        #expect(names.count == Set(names).count, "Duplicate basename found in \(names)")
    }

    @Test("The digest table covers every governed contract fixture")
    func tableCoversExpectedFiles() {
        let fileNames = Set(ContractFixtureDigests.all.map(\.fileName))
        #expect(fileNames == [
            "manifest", "capabilities", "catalog", "decks", "game-lifecycle", "game-list",
            "get-game", "game-update", "mode-turn-zero", "mode-campaign-only",
            "mode-campaign-scenario", "location-enemy-view", "movement",
            "act-no-advance-cost", "investigator-unhealed-horror-negative",
            "uuid-entity-map", "card-code-entity-map", "question-choose-one",
            "question-player-window-choose-one", "question-window-choose-one",
            "answer-question", "question-read", "question-read-with-cards",
            "question-choose-one-location", "question-choose-one-location-multiple",
        ])
    }

    @Test("Synthetic auth fixtures are bundled outside the governed Contract subdirectory")
    func authFixturesStayOutsideContractDirectory() throws {
        let contractNames = try actualBundledFileNames()
        #expect(!contractNames.contains("token"))
        #expect(!contractNames.contains("whoami"))
        // Confirm they still exist, just one directory up, so this isn't vacuously true
        // because the fixtures were deleted rather than deliberately relocated.
        for name in ["token", "whoami"] {
            let url = Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
            #expect(
                url != nil,
                "Expected '\(name).json' to still be bundled under plain Fixtures/"
            )
        }
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

    @Test(
        """
        Every non-manifest registered fixture's basename matches a path the manifest itself \
        documents
        """
    )
    func registeredFixturesMatchManifestPaths() throws {
        struct ManifestFixtureEntry: Decodable {
            let path: String
        }
        struct ManifestFixture: Decodable {
            let fixtures: [ManifestFixtureEntry]
        }
        let manifestData = try fixtureData(named: "manifest")
        let manifest = try JSONDecoder().decode(ManifestFixture.self, from: manifestData)
        let manifestBasenames = Set(
            manifest.fixtures.map { ($0.path as NSString).lastPathComponent }
        )
        for entry in ContractFixtureDigests.all where entry.fileName != "manifest" {
            #expect(
                manifestBasenames.contains("\(entry.fileName).json"),
                """
                Registered fixture '\(entry.fileName).json' has no matching path in the \
                manifest's own fixtures list
                """
            )
        }
    }

    @Test("ContractPin.current is pinned to the documented backend commit")
    func pinnedToDocumentedCommit() {
        #expect(
            ContractPin.current.backendCommit == "52c7ee3b730c87129907e26b91acc3933da841cd"
        )
    }
}
