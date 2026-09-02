@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The fail-closed half of the authority-record count quota: every way
/// the per-call directory census can find something it cannot honestly
/// account for, and the requirement that each of them disables writes
/// rather than quietly proceeding on an under-count.
///
/// Reuses `AssetDiskCacheAuthorityRecordQuotaTests`' fixture helpers by
/// composition, which is also where the reclaim mechanism's ordinary
/// boundary and ordering behaviour is pinned.
@Suite("AssetDiskCache authority record quota fail-closed conditions")
struct AssetDiskCacheRecordQuotaFailClosedTests {
    private let quota = AssetDiskCacheAuthorityRecordQuotaTests()
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    // MARK: - Untrusted entries at an authority-record name

    @Test(
        """
        A non-regular entry (here a directory) occupying an `.applied`-shaped name is an \
        accounting and trust failure, never silently skipped as though it were not there: \
        writes are disabled and the next issuance is refused, exactly as this cache already \
        treats an unaccountable stray at any other reserved name.
        """
    )
    func nonRegularEntryAtAnAuthorityRecordNameFailsClosed() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: quota.limits(maxAuthorityRecordCount: 5)
            )
            try quota.seedSettledRecords(in: directory, indices: 0 ..< 4)
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(quota.syntheticRecordName(99)),
                withIntermediateDirectories: false
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: fixtures.key("01001"))
            }
        }
    }

    @Test(
        """
        A structurally impossible (but perfectly parsable) record occupying an \
        `.applied`-shaped name likewise fails closed rather than being skipped, which would \
        under-count the real file population it occupies.
        """
    )
    func structurallyInvalidRecordFailsClosed() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: quota.limits(maxAuthorityRecordCount: 5)
            )
            try quota.seedSettledRecords(in: directory, indices: 0 ..< 4)
            // Revision 0 is reserved exclusively for the wholly pristine
            // record; this one is not pristine.
            try quota.seedRecord(
                in: directory,
                name: quota.syntheticRecordName(99),
                disposition: .pristine,
                issued: quota.authorityIdentifier(99),
                revision: 0
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: fixtures.key("01001"))
            }
        }
    }

    // MARK: - The directory-scan flood ceiling

    @Test(
        """
        A directory holding more entries than any combination of this cache's own configured \
        budgets could ever legitimately produce is an unaccountable flood: it fails closed \
        immediately, without attempting the per-entry decode/stat pass whose cost is what the \
        ceiling exists to bound. Removing the flood lets a later pass recover normally.
        """
    )
    func anUnaccountableDirectoryFloodFailsClosedImmediately() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = quota.limits(maxAuthorityRecordCount: 4, diskBudgetBytes: 2560)
            #expect(limits.maxAccountableDirectoryEntryCount == 176)
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            var floodNames: [String] = []
            for index in 0 ..< 200 {
                let name = String(format: "flood-%05d.junk", index)
                floodNames.append(name)
                try Data().write(to: directory.appendingPathComponent(name))
            }

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: fixtures.key("01001"))
            }

            for name in floodNames {
                try FileManager.default.removeItem(
                    at: directory.appendingPathComponent(name)
                )
            }
            let recovered = try await cache.beginIssuance(for: fixtures.key("01001"))
            #expect(recovered.authorityID != AuthorityID.pristine)
        }
    }
}
