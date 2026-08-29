@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BundledLocalizedDigestProvider")
struct BundledLocalizedDigestProviderTests {
    @Test("The real bundled resources load successfully and are non-empty except for ko")
    func shippedResourcesLoad() {
        let provider = BundledLocalizedDigestProvider()
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
        let provider = BundledLocalizedDigestProvider()
        #expect(provider.identifierSet(for: .english) == nil)
        #expect(provider.orderedIdentifiers(for: .english) == nil)
        let identifier = try AssetIdentifier.cardCode("01001")
        #expect(!provider.hasLocalizedArt(identifier, locale: .english))
    }

    @Test(
        """
        A bundle that genuinely lacks the expected digest resource traps rather than silently \
        reporting no localized art for every identifier, which would be indistinguishable from a \
        legitimately-empty locale like ko and could mask a packaging regression
        """
    )
    func missingBundledResourceTraps() async {
        // `Bundle.main` (the test executable's own bundle) never contains
        // this package's `Resources/AssetDigests/*.json` resources, so
        // this exercises the genuine-load-failure path without needing to
        // write any files. Exit-test closures cannot capture context, so
        // the provider is constructed inside the closure itself.
        await #expect(processExitsWith: .failure) {
            let provider = BundledLocalizedDigestProvider(bundle: .main)
            _ = provider.identifierSet(for: .french)
        }
    }
}
