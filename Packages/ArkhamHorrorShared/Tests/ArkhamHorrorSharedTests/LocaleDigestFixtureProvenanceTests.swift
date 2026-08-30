@testable import ArkhamHorrorShared
import CryptoKit
import Foundation
import Testing

/// Verifies the *raw* (pre-compaction) localized-digest fixtures vendored under
/// `Fixtures/LocaleDigests/raw/` are byte-identical to a pinned SHA-256 recorded in this
/// same repository (``LocaleDigestFixtureDigests``), and that the registry's own file-name
/// set exactly matches what is actually bundled.
///
/// This only proves internal self-consistency, exactly as ``ContractFixtureDigestTests``
/// documents for the backend contract fixtures: nothing here reaches the network. The
/// network-dependent half -- that these same bytes are still byte-identical to
/// `LocaleDigestProvenance.upstreamCommit` in the real upstream repository -- is
/// `Scripts/verify-locale-digest-provenance.sh`, mirroring
/// `Scripts/verify-contract-fixture-provenance.sh`'s own pattern.
@Suite("LocaleDigestFixtureProvenance")
struct LocaleDigestFixtureProvenanceTests {
    private static let rawSubdirectory = "Fixtures/LocaleDigests/raw"

    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: Self.rawSubdirectory
            )
        )
        return try Data(contentsOf: url)
    }

    /// The file names actually bundled under `Fixtures/LocaleDigests/raw`, derived from the
    /// real resource listing rather than a second hand-maintained literal -- exactly the
    /// same anti-duplication rationale ``ContractFixtureDigestTests``'s own
    /// `actualBundledFileNames()` documents.
    private func actualBundledFileNames() throws -> Set<String> {
        let urls = try #require(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: Self.rawSubdirectory
            ),
            "Expected at least one bundled fixture under \(Self.rawSubdirectory)"
        )
        return Set(urls.map { $0.deletingPathExtension().lastPathComponent })
    }

    @Test("Every registered raw locale digest matches the bundled fixture's actual SHA-256")
    func everyDigestMatchesBundledBytes() throws {
        for entry in LocaleDigestFixtureDigests.all {
            let data = try fixtureData(named: entry.fileName)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            #expect(
                hex == entry.sha256Hex,
                "Raw locale digest '\(entry.fileName).json' has drifted from its pinned SHA-256"
            )
        }
    }

    @Test(
        """
        The registry's file-name set exactly matches what's actually bundled under \
        Fixtures/LocaleDigests/raw
        """
    )
    func registryExactlyMatchesBundledDirectory() throws {
        let registered = Set(LocaleDigestFixtureDigests.all.map(\.fileName))
        let actual = try actualBundledFileNames()
        #expect(
            registered == actual,
            """
            Registry/directory mismatch: registered-only=\(registered.subtracting(actual)), \
            bundled-only=\(actual.subtracting(registered))
            """
        )
    }

    @Test("The registry has no duplicate basename")
    func registryHasNoDuplicateBasename() {
        let names = LocaleDigestFixtureDigests.all.map(\.fileName)
        #expect(names.count == Set(names).count, "Duplicate basename found in \(names)")
    }

    @Test("The registry covers every AssetLocale that ships a localized digest resource")
    func registryCoversEveryShippedLocale() {
        let registeredNames = Set(LocaleDigestFixtureDigests.all.map(\.fileName))
        let shippedLocales: [AssetLocale] = [.italian, .french, .spanish, .korean, .chinese]
        for locale in shippedLocales {
            let resourceName = locale.digestResourceName
            #expect(
                resourceName != nil,
                "Expected \(locale) to have a shipped digest resource name"
            )
            if let resourceName {
                #expect(
                    registeredNames.contains(resourceName),
                    "Registry is missing an entry for shipped locale resource '\(resourceName)'"
                )
            }
        }
    }

    @Test("LocaleDigestProvenance is pinned to the documented upstream commit")
    func pinnedToDocumentedCommit() {
        #expect(LocaleDigestProvenance.upstreamCommit == "6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27")
        #expect(
            LocaleDigestProvenance.upstreamRepositoryURL
                == "https://github.com/djensenius/ArkhamHorror.git"
        )
    }
}
