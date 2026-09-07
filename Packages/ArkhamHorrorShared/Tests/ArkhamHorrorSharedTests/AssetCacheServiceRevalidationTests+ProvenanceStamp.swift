@testable import ArkhamHorrorShared
import Foundation
import Testing

/// `assembleRevalidatedAsset(request:response:)` unit-level coverage: the
/// step a coalesced revalidation's transport pipeline hands its fresh
/// `AssetHTTPResponse` off to for validation and disk/memory assembly.
/// Split out of `AssetCacheServiceRevalidationTests.swift` purely to stay
/// under SwiftLint's `file_length`, the same way that file was itself
/// split from `AssetCacheServiceTests.swift`; still part of the single
/// `AssetCacheServiceTests` suite/`AssetCacheService+RevalidationCoalescing.swift`
/// concern.
extension AssetCacheServiceTests {
    /// Shared fixture for the pair of tests below: a `cardArtKey` (whose
    /// own category default format is AVIF) paired with a genuinely valid
    /// PNG revalidation response, so `expectedFormat: .png` passed
    /// explicitly must succeed while `expectedFormat: key.expectedFormat`
    /// (AVIF) must fail against the identical bytes.
    private struct MismatchedFormatFixture {
        let key: AssetKey
        let cacheKey: AssetCacheKey
        let url: URL
        let existing: CachedAsset
        let response: AssetHTTPResponse
    }

    /// A token stamped exactly the way every real production call site
    /// stamps one: ``AssetCacheService/issueToken(for:)``'s synchronous
    /// in-memory half, combined with
    /// ``AssetCacheService/beginIssuance(for:)``'s durable
    /// clear-epoch/disk-write-generation snapshot -- unlike a bare
    /// `issueToken(for:)` result alone, which (correctly) never carries
    /// either durable field, since real callers only reach
    /// `assembleRevalidatedAsset` after also durably stamping a token
    /// this way (see `AssetCacheService+RevalidationCoalescing.swift`'s
    /// `coalescedRevalidation`/`resolveOrIssueRevalidation`).
    private func fullyIssuedToken(
        _ service: AssetCacheService,
        for cacheKey: AssetCacheKey
    ) async -> AssetCacheService.CacheToken {
        let issued = await service.issueToken(for: cacheKey)
        let authority = await service.beginIssuance(for: cacheKey)
        return AssetCacheService.CacheToken(
            generation: issued.generation,
            issuance: issued.issuance,
            clearGeneration: issued.clearGeneration,
            durableClearEpoch: authority.clearEpoch,
            diskAuthorityID: authority.diskAuthorityID
        )
    }

    private func mismatchedFormatFixture() throws -> MismatchedFormatFixture {
        let key = try cardArtKey()
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        let url = try #require(URL(string: "https://example.com/cards/01001.png"))
        let existing = CachedAsset(
            payload: AssetImageFixtureBuilder.validAVIF(width: 4, height: 4),
            metadata: AssetCacheMetadata(
                cacheKeyHex: cacheKey.digestHex,
                contentType: "image/avif",
                encodedByteCount: 10,
                width: 4,
                height: 4,
                payloadSHA256Hex: AssetPayloadHasher.sha256Hex(Data([0])),
                etag: "\"old\"",
                lastModified: nil,
                resolvedURLString: url.absoluteString,
                insertedAt: Date(timeIntervalSince1970: 0),
                accessSequence: AssetAccessSequence(0)
            )
        )
        let response = AssetHTTPResponse(
            body: AssetImageFixtureBuilder.validPNG(width: 4, height: 4),
            contentType: "image/png",
            etag: "\"new\"",
            lastModified: nil
        )
        return MismatchedFormatFixture(
            key: key,
            cacheKey: cacheKey,
            url: url,
            existing: existing,
            response: response
        )
    }

    @Test(
        """
        assembleRevalidatedAsset never fabricates clearEpochAtPublication/ \
        authorityIDAtPublication with 0 when the token's own durable epoch/ticket \
        is nil (a durable read/reservation failure at issuance time): it fails exactly like \
        isAuthoritative(_:for:) would have, rather than assembling a not-yet-authoritative \
        asset with a falsely-plausible provenance stamp
        """
    )
    func assembleRevalidatedAssetFailsRatherThanFabricatingNilProvenanceStamps() async throws {
        let fixture = try mismatchedFormatFixture()
        try await withService { service, _ in
            let issued = await service.issueToken(for: fixture.cacheKey)
            let unstampedToken = AssetCacheService.CacheToken(
                generation: issued.generation,
                issuance: issued.issuance,
                clearGeneration: issued.clearGeneration,
                durableClearEpoch: nil,
                diskAuthorityID: nil
            )
            let request = AssetCacheService.RevalidationRequest(
                cacheKey: fixture.cacheKey,
                url: fixture.url,
                expectedFormat: .png,
                existing: fixture.existing,
                etag: nil,
                lastModified: nil,
                token: unstampedToken
            )
            await #expect(throws: AssetError.staleOperation) {
                _ = try await service.assembleRevalidatedAsset(
                    request: request,
                    response: fixture.response
                )
            }
        }
    }

    @Test(
        """
        assembleRevalidatedAsset validates a fresh revalidation response against \
        the passed-in expectedFormat (the resolved candidate's own format \
        recovered by revalidate(for:)): a PNG response validates and publishes \
        successfully when expectedFormat: .png is passed explicitly, even though \
        this key's own category default format is AVIF
        """
    )
    func assembleRevalidatedAssetValidatesAgainstThePassedFormat() async throws {
        let fixture = try mismatchedFormatFixture()
        try await withService { service, _ in
            let token = await fullyIssuedToken(service, for: fixture.cacheKey)
            let request = AssetCacheService.RevalidationRequest(
                cacheKey: fixture.cacheKey,
                url: fixture.url,
                expectedFormat: .png,
                existing: fixture.existing,
                etag: nil,
                lastModified: nil,
                token: token
            )
            let asset = try await service.assembleRevalidatedAsset(
                request: request,
                response: fixture.response
            )
            #expect(asset.metadata.contentType == "image/png")
            #expect(asset.metadata.width == 4)
            #expect(asset.metadata.height == 4)
            #expect(asset.metadata.insertedAt == fixture.existing.metadata.insertedAt)
        }
    }

    @Test(
        """
        assembleRevalidatedAsset never falls back to key.expectedFormat: \
        validating the identical PNG response bytes against this AVIF-art \
        key's own default format fails, proving the resolved candidate's \
        format -- not the key's -- must drive validation
        """
    )
    func assembleRevalidatedAssetNeverFallsBackToKeyExpectedFormat() async throws {
        let fixture = try mismatchedFormatFixture()
        #expect(fixture.key.expectedFormat == .avif)
        try await withService { service, _ in
            let token = await fullyIssuedToken(service, for: fixture.cacheKey)
            let request = AssetCacheService.RevalidationRequest(
                cacheKey: fixture.cacheKey,
                url: fixture.url,
                expectedFormat: fixture.key.expectedFormat,
                existing: fixture.existing,
                etag: nil,
                lastModified: nil,
                token: token
            )
            await #expect(throws: (any Error).self) {
                _ = try await service.assembleRevalidatedAsset(
                    request: request,
                    response: fixture.response
                )
            }
        }
    }
}
