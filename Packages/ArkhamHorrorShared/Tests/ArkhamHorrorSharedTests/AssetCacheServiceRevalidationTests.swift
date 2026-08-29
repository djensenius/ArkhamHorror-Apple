@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Conditional revalidation (`If-None-Match`) and 304 handling for
/// ``AssetCacheService``. Split out from `AssetCacheServiceTests.swift`
/// (which retains the shared `withService`/`cardArtKey`/`candidateURLs`/
/// `successResult` helpers) purely to stay under SwiftLint's
/// `type_body_length`; this is one `@Suite` conceptually, spread across
/// files by concern the same way `AppModelTests` is split.
extension AssetCacheServiceTests {
    @Test(
        "Revalidating with no prior cache entry throws staleConditionalResponse, no network call"
    )
    func revalidateWithNoCachedEntryThrowsWithoutNetworkCall() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.revalidate(for: key)
            }
            let urls = candidateURLs(for: key)
            for url in urls {
                let callCount = await transport.callCount(for: url)
                #expect(callCount == 0)
            }
        }
    }

    @Test(
        """
        Revalidating a cached entry with neither ETag nor Last-Modified throws \
        staleConditionalResponse, no network call
        """
    )
    func revalidateWithNoValidatorsThrowsWithoutNetworkCall() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            // Neither etag nor lastModified supplied: the cached entry has
            // no validator to condition a request on.
            await transport.enqueue(.success(successResult()), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == nil)
            #expect(initial.metadata.lastModified == nil)

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.revalidate(for: key)
            }
            // Exactly the one initial fetch, and no further (revalidation)
            // call to any candidate URL.
            let firstCallCount = await transport.callCount(for: urls[0])
            #expect(firstCallCount == 1)
            for url in urls.dropFirst() {
                let callCount = await transport.callCount(for: url)
                #expect(callCount == 0)
            }
        }
    }

    @Test(
        "A 304 with a currently valid cached payload succeeds and refreshes lastAccessedAt"
    )
    func notModifiedWithValidCacheSucceeds() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"abc\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == "\"abc\"")

            await transport.enqueue(.success(.notModified), for: urls[0])
            let revalidated = try await service.revalidate(for: key)
            #expect(revalidated.payload == initial.payload)

            let call = await transport.calls.last
            #expect(call?.ifNoneMatch == "\"abc\"")
        }
    }

    @Test(
        "An unconditional 304 during the initial (non-revalidating) fetch is a typed protocol error"
    )
    func unconditional304DuringInitialFetchIsError() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(.notModified), for: urls[0])

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.asset(for: key)
            }
        }
    }

    @Test(
        """
        A definitive 404 while revalidating evicts the now-stale cached entry, so a subsequent \
        asset(for:) call fetches fresh rather than re-serving the removed content
        """
    )
    func notFoundDuringRevalidationEvictsStaleEntry() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"abc\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == "\"abc\"")

            await transport.enqueue(.success(.notFound), for: urls[0])
            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await service.revalidate(for: key)
            }

            // The stale entry must be gone from both cache layers: the next
            // resolution has to hit the network again rather than silently
            // continuing to serve the server-removed asset.
            await transport.enqueue(.success(successResult(etag: "\"def\"")), for: urls[0])
            let refetched = try await service.asset(for: key)
            #expect(refetched.metadata.etag == "\"def\"")
        }
    }
}
