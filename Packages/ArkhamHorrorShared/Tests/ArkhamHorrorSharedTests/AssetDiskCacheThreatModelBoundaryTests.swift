@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Pins the *boundary* of what ``AssetDiskCache``'s durable authority
/// record claims to defend, so a future reader can tell a deliberate
/// non-goal apart from an oversight.
///
/// See the "Threat model" section of
/// `AssetDiskCache+Disposition.swift`'s type-level documentation for the
/// full statement. In short: this design defends against crashes and
/// torn writes, against concurrent instances and processes under its own
/// exclusive lock, and against missing or corrupt state (which always
/// fails closed). It does **not** defend against an actor who can write
/// directly into this cache's directory outside the app's own write
/// path -- including one who restores an older, perfectly well-formed,
/// fully-committed snapshot of a key's `<hash>.applied` record. No
/// purely local, app-owned-filesystem scheme can distinguish that from
/// "this file was simply never touched since", because any second copy,
/// mirror, witness, or journal added to try is equally restorable by the
/// same actor.
@Suite("AssetDiskCache authority record threat model boundary")
struct AssetDiskCacheThreatModelBoundaryTests {
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    @Test(
        """
        DOCUMENTS AN ACCEPTED, OUT-OF-SCOPE THREAT -- NOT A PASSING SECURITY CONTROL. \
        Restoring a key's authority record byte-for-byte from an earlier, valid, \
        fully-committed snapshot of that same file, while this cache holds no lock, is \
        silently accepted: the very next legitimate operation for that key simply continues \
        from the restored state as though the intervening transitions had never happened. \
        This test exists to prove the boundary is exactly where the threat-model \
        documentation says it is; if it ever starts failing, the design has grown a \
        detection mechanism that documentation no longer describes.
        """
    )
    func externallyRestoredEarlierAuthorityRecordIsAccepted() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let cacheKey = try fixtures.key("01001")
            let recordURL = await directory.appendingPathComponent(
                cache.authorityRecordFilename(for: cacheKey)
            )

            let token = try await fixtures.issuedToken(from: cache, for: cacheKey)
            let payload = Data([4, 5, 6])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: fixtures.metadata(for: cacheKey, payload: payload),
                token: token
            )
            let published = try await cache.currentKeyRecord(for: cacheKey)
            #expect(published.disposition.kind == .content)

            // An ordinary, honest snapshot: whatever a backup, a
            // filesystem clone, or a curious user with a copy of this
            // directory would have captured at this instant.
            let snapshotBytes = try Data(contentsOf: recordURL)

            try await cache.remove(cacheKey)
            let settled = try await cache.currentKeyRecord(for: cacheKey)
            #expect(settled.disposition.kind == .tombstone)
            #expect(settled.transitionRevision > published.transitionRevision)
            #expect(try Data(contentsOf: recordURL) != snapshotBytes)

            // The out-of-scope act: an external writer puts the earlier
            // file back, byte for byte, while nothing holds the lock.
            try snapshotBytes.write(to: recordURL)

            let afterRestore = try await cache.currentKeyRecord(for: cacheKey)
            #expect(
                afterRestore == published,
                """
                ACCEPTED, BY DESIGN: the restored record is indistinguishable from one that \
                was never superseded, and is read back as this key's authority.
                """
            )

            let reissued = try await cache.beginIssuance(for: cacheKey)
            #expect(
                reissued.revision == published.transitionRevision + 1,
                """
                ACCEPTED, BY DESIGN: the next legitimate operation proceeds with no error \
                and no special detection, continuing the restored history rather than the \
                real one.
                """
            )
            #expect(
                reissued.authorityID != published.issuedAuthorityID,
                """
                The one thing that IS guaranteed regardless: every issuance mints a fresh \
                128-bit random authority, so even a restored record can never cause a \
                previously-issued identifier to be handed out a second time.
                """
            )
        }
    }
}
