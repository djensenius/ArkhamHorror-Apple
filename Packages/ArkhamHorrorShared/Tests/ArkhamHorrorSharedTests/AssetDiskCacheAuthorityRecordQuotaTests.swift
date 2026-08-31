@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The *count* half of ``AssetDiskCache``'s quota: every durable
/// per-key authority record (`<hash>.applied`) this cache ever writes is
/// bounded by ``AssetCacheLimits/maxAuthorityRecordCount``, reclaimed
/// when it can be, and fails closed when it cannot.
///
/// The finding this pins: one authority record is durably written for
/// every key that is ever *issued*, including the (very common) keys
/// that never publish a byte -- a transport failure, a 404, a cancelled
/// fetch. Those files used to have no reclaim path at all short of a
/// whole-cache clear, so a workload of thousands of distinct,
/// never-republished URLs accumulated them without limit: an inode/
/// metadata exhaustion vector on its own, and, because every single
/// issuance now proves the budget with a full directory listing, an
/// ever-growing per-issuance cost.
@Suite("AssetDiskCache authority record count quota")
struct AssetDiskCacheAuthorityRecordQuotaTests {
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    func limits(
        maxAuthorityRecordCount: Int,
        diskBudgetBytes: Int = 4_000_000
    ) -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: diskBudgetBytes,
            maxAuthorityRecordCount: maxAuthorityRecordCount
        )
    }

    /// A synthetic key-hash-shaped name, so a test can seed authority
    /// records for thousands of distinct "keys" without paying for a real
    /// ``AssetCacheKey`` derivation per record. Nothing in the count
    /// quota interprets the hash itself; it is only ever an opaque,
    /// deterministic leaf name.
    func syntheticRecordName(_ index: Int) -> String {
        String(format: "%064x", index) + AssetDiskCache.authorityRecordFilenameSuffix
    }

    func authorityIdentifier(_ index: Int) throws -> AuthorityID {
        try #require(AuthorityID(hexString: String(format: "%032x", index + 1)))
    }

    /// Writes one record byte-for-byte in the shape ``AssetDiskCache``
    /// itself commits: a never-published, issued-once key carries the
    /// pristine `.tombstone` disposition it inherited, which is exactly
    /// what a transport failure or a 404 leaves behind.
    func seedRecord(
        in directory: URL,
        name: String,
        disposition: AssetDiskCache.KeyDisposition,
        issued: AuthorityID,
        revision: Int
    ) throws {
        let record = AssetDiskCache.KeyAuthorityRecord(
            issuedAuthorityID: issued,
            disposition: disposition,
            transitionRevision: revision
        )
        try JSONEncoder.assetCache().encode(record)
            .write(to: directory.appendingPathComponent(name))
    }

    func seedSettledRecords(
        in directory: URL,
        indices: Range<Int>,
        firstRevision: Int = 1
    ) throws {
        for index in indices {
            try seedRecord(
                in: directory,
                name: syntheticRecordName(index),
                disposition: .pristine,
                issued: authorityIdentifier(index),
                revision: firstRevision + index - indices.lowerBound
            )
        }
    }

    /// Establishes this root's durable clear-epoch authority before any
    /// record is planted by hand. A brand-new root only initializes that
    /// authority on its first real locked operation, and a root holding
    /// surviving entries without it is (correctly) refused as an
    /// un-fenced resurrection rather than treated as pristine -- so a
    /// test that seeds files must first let the cache own its root.
    func bootstrapRoot(_ cache: AssetDiskCache, in directory: URL) async throws {
        _ = try await cache.beginIssuance(for: fixtures.key("09999"))
        for name in try recordNames(in: directory) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func recordNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(AssetDiskCache.authorityRecordFilenameSuffix) }
            .sorted()
    }

    // MARK: - Exact boundary

    @Test(
        """
        A population sitting exactly AT the high-water mark is left completely alone -- no \
        record is reclaimed and the issuance that observed it still commits its own record. \
        The very next issuance, which observes one record more than the mark, reclaims down \
        to the low-water mark BEFORE committing its own, so the projected write is accounted \
        for in advance rather than discovered after the fact.
        """
    )
    func reclaimTriggersOneRecordPastTheHighWaterMarkAndNotAtIt() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 10)
            #expect(limits.highWaterMarkAuthorityRecordCount == 9)
            #expect(limits.lowWaterMarkAuthorityRecordCount == 7)
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            try await bootstrapRoot(cache, in: directory)
            // Nine settled records, deliberately given HIGH revisions so
            // the record the first issuance below writes (revision 1)
            // sorts ahead of every one of them for reclaim.
            try seedSettledRecords(in: directory, indices: 0 ..< 9, firstRevision: 10)
            #expect(try recordNames(in: directory).count == 9)

            let first = try await cache.beginIssuance(for: fixtures.key("01001"))
            #expect(first.revision == 1)
            #expect(
                try recordNames(in: directory).count == 10,
                "Exactly at the high-water mark, nothing is reclaimed"
            )

            let second = try await cache.beginIssuance(for: fixtures.key("01002"))
            #expect(second.revision == 1)
            let survivors = try recordNames(in: directory)
            #expect(
                survivors.count == 8,
                "One past the mark reclaims to the low-water mark (7), then commits its own"
            )
            // The two lowest-revision seeded records went first, after
            // the even-lower-revision record the previous issuance wrote.
            #expect(survivors.contains(syntheticRecordName(0)) == false)
            #expect(survivors.contains(syntheticRecordName(1)) == false)
            #expect(survivors.contains(syntheticRecordName(2)))
            #expect(survivors.contains(syntheticRecordName(8)))
        }
    }

    // MARK: - Only settled records are ever reclaimed, oldest revision first

    @Test(
        """
        Reclaim only ever removes records whose disposition is a settled tombstone, oldest \
        transition revision first; a record still holding live content survives every amount \
        of file-count pressure, and is only ever removed through the ordinary content path.
        """
    )
    func onlySettledRecordsAreReclaimedOldestRevisionFirst() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            try await bootstrapRoot(cache, in: directory)
            let liveName = syntheticRecordName(100)
            try seedRecord(
                in: directory,
                name: liveName,
                disposition: AssetDiskCache.KeyDisposition(
                    authorityID: authorityIdentifier(100),
                    kind: .content,
                    contentHash: AssetPayloadHasher.sha256Hex(Data([1]))
                ),
                issued: authorityIdentifier(100),
                // Deliberately the OLDEST revision of them all: were
                // liveness not checked, this would be the very first
                // record reclaim removed.
                revision: 1
            )
            try seedSettledRecords(in: directory, indices: 0 ..< 4, firstRevision: 10)
            #expect(try recordNames(in: directory).count == 5)

            _ = try await cache.beginIssuance(for: fixtures.key("01001"))
            let survivors = try recordNames(in: directory)
            #expect(survivors.count == 4, "Reclaimed to the low-water mark (3), then committed")
            #expect(survivors.contains(liveName), "A live content record is never reclaimed")
            #expect(survivors.contains(syntheticRecordName(0)) == false)
            #expect(survivors.contains(syntheticRecordName(1)) == false)
            #expect(survivors.contains(syntheticRecordName(2)))
            #expect(survivors.contains(syntheticRecordName(3)))
        }
    }

    // MARK: - Uncorrectable over-cap, and recovery

    @Test(
        """
        When every record over the cap is live and therefore unreclaimable, this is a real, \
        uncorrectable over-budget condition: disk writes are durably disabled and the next \
        legitimate issuance is refused with a typed error rather than silently allowed \
        through. Once the live population genuinely drops (a whole-cache clear), writes \
        re-enable exactly like every other disabled-writes recovery path.
        """
    )
    func uncorrectableLiveOverCapDisablesWritesUntilTheLivePopulationDrops() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            try await bootstrapRoot(cache, in: directory)
            for index in 0 ..< 5 {
                try seedRecord(
                    in: directory,
                    name: syntheticRecordName(index),
                    disposition: AssetDiskCache.KeyDisposition(
                        authorityID: authorityIdentifier(index),
                        kind: .content,
                        contentHash: AssetPayloadHasher.sha256Hex(Data([UInt8(index)]))
                    ),
                    issued: authorityIdentifier(index),
                    revision: 2
                )
            }

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: fixtures.key("01001"))
            }
            #expect(
                try recordNames(in: directory).count == 5,
                "A refused issuance writes nothing, and reclaims nothing it may not reclaim"
            )

            try await cache.removeAll()
            let reissued = try await cache.beginIssuance(for: fixtures.key("01001"))
            #expect(reissued.authorityID != AuthorityID.pristine)
            #expect(reissued.revision == 1)
        }
    }
}
