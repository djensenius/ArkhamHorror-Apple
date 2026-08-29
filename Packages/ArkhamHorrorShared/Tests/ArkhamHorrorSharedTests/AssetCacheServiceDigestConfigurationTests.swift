@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Digest-configuration-failure propagation for ``AssetCacheService``.
/// Split out from `AssetCacheServiceTests.swift` (which retains the
/// shared `withService`/`cardArtKey`/`candidateURLs` helpers) purely to
/// stay under SwiftLint's `type_body_length`; this is one `@Suite`
/// conceptually, spread across files by concern the same way
/// `AppModelTests` is split.
extension AssetCacheServiceTests {
    @Test(
        """
        A broken digest configuration (the default-production BundledLocalizedDigestProvider's \
        shape when its bundled resource fails to load) surfaces as a typed configurationFailure \
        immediately, rather than silently falling back to an English candidate as if the \
        identifier simply had no localized art
        """
    )
    func brokenDigestConfigurationSurfacesRatherThanFallingBackToEnglish() async throws {
        let failure = AssetError.configurationFailure("digest resource missing")
        let digest = FailingDigestLookup(configurationError: failure)
        try await withService(digest: digest) { service, transport in
            let key = try cardArtKey()
            // No response is ever enqueued: a fallback-to-English would
            // attempt a network call this fake transport has nothing
            // queued for, and would fail with a different, misleading
            // error if this test's real assertion below were wrong.
            await #expect(throws: failure) {
                _ = try await service.asset(for: key)
            }
            #expect(await transport.callCount(for: candidateURLs(for: key)[0]) == 0)
        }
    }
}
