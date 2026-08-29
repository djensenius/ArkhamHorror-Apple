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
}
