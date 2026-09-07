@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The rollback/regression half of the random-authority redesign's
/// acceptance suite (see `AssetDiskCacheAuthorityIssuanceTests.swift`
/// for the issuance half, whose fixture helpers this file reuses by
/// composition).
///
/// Exercises ``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``
/// directly -- the single durable commit choke point every mutation
/// path funnels through -- with records no legitimate mutation path
/// would ever construct, to pin the two rules that keep the canonical
/// record from being walked backward: the checked `transitionRevision`
/// increment, and disposition-transition legality at an identifier that
/// has already committed something.
@Suite("AssetDiskCache authority record rollback rejection")
struct AssetDiskCacheAuthorityRollbackTests {
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    /// The disposition shape a single direct commit attempt should try
    /// to write. Bundled into one value purely to keep
    /// ``commitSucceeds(on:for:authorityID:attempt:)`` within this
    /// package's `function_parameter_count` convention.
    private struct Attempt {
        let kind: AssetDiskCache.KeyDispositionKind
        let contentHash: String?
        let revision: Int
    }

    /// Attempts one direct durable commit of an explicitly-shaped
    /// record, reporting only whether it was accepted -- so a test can
    /// assert on the commit choke point's own transition legality and
    /// checked-revision rules without going through a mutation path that
    /// would construct a well-formed record for it.
    private func commitSucceeds(
        on cache: AssetDiskCache,
        for cacheKey: AssetCacheKey,
        authorityID: AuthorityID,
        attempt: Attempt
    ) async -> Bool {
        do {
            try await cache.commitAuthorityRecordLocked(
                AssetDiskCache.KeyAuthorityRecord(
                    issuedAuthorityID: authorityID,
                    disposition: AssetDiskCache.KeyDisposition(
                        authorityID: authorityID,
                        kind: attempt.kind,
                        contentHash: attempt.contentHash
                    ),
                    transitionRevision: attempt.revision
                ),
                for: cacheKey
            )
            return true
        } catch {
            return false
        }
    }

    /// Everything a rollback attempt needs in order to describe itself
    /// against an already-settled durable record.
    private struct PublishedFixture {
        let cache: AssetDiskCache
        let cacheKey: AssetCacheKey
        let authorityID: AuthorityID
        let contentHash: String
        let revision: Int
    }

    /// Publishes one entry and returns the settled state that resulted.
    private func publishedFixture(in directory: URL) async throws -> PublishedFixture {
        let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
        let cacheKey = try fixtures.key("01001")
        let token = try await fixtures.issuedToken(from: cache, for: cacheKey)
        let payload = Data([4, 5, 6])
        try await cache.set(
            cacheKey,
            payload: payload,
            metadata: fixtures.metadata(for: cacheKey, payload: payload),
            token: token
        )
        let authorityID = try #require(token.diskAuthorityID)
        let record = try await cache.currentKeyRecord(for: cacheKey)
        #expect(record.issuedAuthorityID == authorityID)
        #expect(record.disposition.kind == .content)
        return PublishedFixture(
            cache: cache,
            cacheKey: cacheKey,
            authorityID: authorityID,
            contentHash: AssetPayloadHasher.sha256Hex(payload),
            revision: record.transitionRevision
        )
    }

    @Test(
        """
        A commit carrying the SAME authority identifier as an already-committed content \
        disposition, but a transition revision that does not advance by exactly one, is \
        rejected -- whether it rolls the revision backward or merely replays the current one.
        """
    )
    func sameIdentifierRevisionRollbackIsRejected() async throws {
        try await fixtures.withScratchDirectory { directory in
            let published = try await publishedFixture(in: directory)
            for revision in [published.revision - 1, published.revision] {
                let accepted = await commitSucceeds(
                    on: published.cache,
                    for: published.cacheKey,
                    authorityID: published.authorityID,
                    attempt: Attempt(
                        kind: .content,
                        contentHash: published.contentHash,
                        revision: revision
                    )
                )
                #expect(
                    accepted == false,
                    "A commit must advance the transition revision by exactly one"
                )
            }
            let unchanged = try await published.cache.currentKeyRecord(for: published.cacheKey)
            #expect(unchanged.transitionRevision == published.revision)
            #expect(unchanged.disposition.kind == .content)
        }
    }

    @Test(
        """
        At an identifier that has already committed a content disposition, only the genuine \
        forward edges this cache can actually produce are accepted: re-pointing that same \
        identifier at different bytes is rejected, content -> retiring is accepted, and \
        resurrecting the retired identifier back into content is rejected again.
        """
    )
    func sameIdentifierDispositionRegressionIsRejected() async throws {
        try await fixtures.withScratchDirectory { directory in
            let published = try await publishedFixture(in: directory)

            func attemptCommit(_ attempt: Attempt) async -> Bool {
                await commitSucceeds(
                    on: published.cache,
                    for: published.cacheKey,
                    authorityID: published.authorityID,
                    attempt: attempt
                )
            }

            #expect(
                await attemptCommit(
                    Attempt(
                        kind: .content,
                        contentHash: AssetPayloadHasher.sha256Hex(Data([9])),
                        revision: published.revision + 1
                    )
                ) == false,
                "An already-committed identifier can never be re-pointed at different bytes"
            )
            #expect(
                await attemptCommit(
                    Attempt(kind: .retiring, contentHash: nil, revision: published.revision + 1)
                ),
                "content -> retiring at the same identifier is a legal forward edge"
            )
            #expect(
                await attemptCommit(
                    Attempt(
                        kind: .content,
                        contentHash: published.contentHash,
                        revision: published.revision + 2
                    )
                ) == false,
                "A retired identifier can never be resurrected back into content"
            )

            let final = try await published.cache.currentKeyDisposition(for: published.cacheKey)
            #expect(final.kind == .retiring)
            #expect(final.authorityID == published.authorityID)
        }
    }
}
