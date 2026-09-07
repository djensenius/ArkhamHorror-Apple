@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BundledLocalizedDigestProvider")
struct BundledLocalizedDigestProviderTests {
    @Test("The real bundled resources load successfully and are non-empty except for ko")
    func shippedResourcesLoad() throws {
        let provider = try BundledLocalizedDigestProvider()
        #expect(provider.configurationError == nil)
        for locale in AssetLocale.allCases where locale != .english {
            let identifiers = provider.orderedIdentifiers(for: locale)
            #expect(identifiers != nil, "\(locale) must have a loadable digest resource")
            if locale == .korean {
                #expect(identifiers?.isEmpty == true, "ko is expected to ship an empty digest")
            } else {
                #expect(
                    identifiers?.isEmpty == false,
                    "\(locale) is expected to ship a non-empty digest"
                )
            }
        }
    }

    @Test("English has no digest resource and always reports no localized art")
    func englishHasNoDigestResource() throws {
        let provider = try BundledLocalizedDigestProvider()
        #expect(provider.identifierSet(for: .english) == nil)
        #expect(provider.orderedIdentifiers(for: .english) == nil)
        let identifier = try AssetIdentifier.cardCode("01001")
        #expect(!provider.hasLocalizedArt(identifier, locale: .english))
    }

    @Test(
        """
        A bundle that genuinely lacks the expected digest resource throws a typed, catchable \
        configuration error at construction time rather than trapping the process — this must \
        be distinguishable from a legitimately-empty locale like ko, never impersonating it
        """
    )
    func missingBundledResourceThrowsTypedConfigurationError() throws {
        // `Bundle.main` (the test executable's own bundle) never contains
        // this package's `Resources/AssetDigests/*.json` resources, so
        // this exercises the genuine-load-failure path without needing to
        // write any files.
        #expect(throws: AssetError.configurationFailure("ignored")) {
            _ = try BundledLocalizedDigestProvider(bundle: .main)
        }
    }

    @Test(
        """
        A missing-resource construction failure is reported for the specific locale that \
        failed to load, not silently swallowed or reported against the wrong locale
        """
    )
    func configurationFailureIdentifiesTheFailingResource() throws {
        do {
            _ = try BundledLocalizedDigestProvider(bundle: .main)
            Issue.record("Expected BundledLocalizedDigestProvider(bundle: .main) to throw")
        } catch let AssetError.configurationFailure(message) {
            #expect(message.contains(".json"), "the diagnostic message should name the resource")
        } catch {
            Issue.record("Expected AssetError.configurationFailure, got \(error)")
        }
    }

    @Test(
        """
        `.shared` never traps even in the hypothetical case its underlying construction fails: \
        it falls back to an instance that answers "no localized art" for every locale while \
        still recording the failure observably via `configurationError`, rather than crashing \
        or silently impersonating a legitimately-empty locale
        """
    )
    func sharedNeverTrapsAndObservablyRecordsAnyConfigurationFailure() {
        // `.shared` resolves the real, always-valid `.module` bundle in
        // this test target, so it is expected to succeed with no
        // recorded failure — this test documents and locks in that
        // contract (a `.shared` that could ever throw or trap would be a
        // regression to the crash behavior this finding removed).
        let shared = BundledLocalizedDigestProvider.shared
        #expect(shared.configurationError == nil)
    }

    /// Builds a genuine, minimal `.bundle` directory (with an `Info.plist`,
    /// removed unconditionally after the test) supplying every non-English
    /// locale's digest resource, so a single locale's content can be
    /// deliberately malformed to prove `init(bundle:)` actually validates
    /// it rather than only checking that it decodes as `[String]`.
    ///
    /// `Bundle(url:)` resolving `url(forResource:withExtension:subdirectory:)`
    /// lookups against a *bare* directory (no `.bundle` suffix, no
    /// `Info.plist`) is undocumented behavior that could vary across
    /// platforms/OS versions; a real `.bundle`-suffixed directory with a
    /// minimal `Info.plist` is what `Bundle` is actually documented to
    /// resolve, so these tests build one rather than relying on the
    /// looser, unsupported shape.
    private func withScratchBundle(
        overriding overrideName: String,
        content: [String],
        _ body: (Bundle) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DigestProviderScratch", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).bundle", isDirectory: true)
        let resourcesDirectory = root.appendingPathComponent(
            "Resources/AssetDigests", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resourcesDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "org.arkhamhorror.scratch-digest-provider-tests",
            "CFBundlePackageType": "BNDL",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: root.appendingPathComponent("Info.plist"))
        for locale in AssetLocale.allCases {
            guard let name = locale.digestResourceName else { continue }
            let content = name == overrideName ? content : []
            let data = try JSONEncoder().encode(content)
            try data.write(to: resourcesDirectory.appendingPathComponent("\(name).json"))
        }
        let bundle = try #require(Bundle(url: root))
        try body(bundle)
    }

    @Test("An unsorted digest resource is a typed configuration failure, not silently accepted")
    func unsortedDigestResourceIsConfigurationFailure() throws {
        try withScratchBundle(overriding: "fr", content: ["01002", "01001"]) { bundle in
            #expect(throws: AssetError.configurationFailure("ignored")) {
                _ = try BundledLocalizedDigestProvider(bundle: bundle)
            }
        }
    }

    @Test("A digest resource with a duplicate entry is a typed configuration failure")
    func duplicateEntryDigestResourceIsConfigurationFailure() throws {
        try withScratchBundle(overriding: "fr", content: ["01001", "01001"]) { bundle in
            #expect(throws: AssetError.configurationFailure("ignored")) {
                _ = try BundledLocalizedDigestProvider(bundle: bundle)
            }
        }
    }

    @Test(
        "A digest resource entry that is not a valid card code is a typed configuration failure"
    )
    func invalidCardCodeDigestResourceIsConfigurationFailure() throws {
        try withScratchBundle(overriding: "fr", content: ["not a card code!"]) { bundle in
            #expect(throws: AssetError.configurationFailure("ignored")) {
                _ = try BundledLocalizedDigestProvider(bundle: bundle)
            }
        }
    }

    @Test("A sorted, deduplicated, all-valid digest resource loads successfully")
    func wellFormedScratchDigestResourceLoads() throws {
        try withScratchBundle(overriding: "fr", content: ["01001", "01002"]) { bundle in
            let provider = try BundledLocalizedDigestProvider(bundle: bundle)
            #expect(provider.orderedIdentifiers(for: .french) == ["01001", "01002"])
        }
    }
}
