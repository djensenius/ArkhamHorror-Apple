@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The durability half of the random-authority redesign's acceptance
/// suite (see `AssetDiskCacheAuthorityIssuanceTests.swift` for the
/// issuance/CAS half, whose scratch-directory and fixture helpers this
/// file reuses by composition).
///
/// Covers the two scenarios that are about *what survives a failure*
/// rather than about identifier semantics: a fresh-root bootstrap that
/// cannot be proven durable must fence the clear rather than silently
/// proceed, and every crash point in the single canonical record's
/// atomic write must leave that record wholly old or wholly new.
@Suite("AssetDiskCache authority record durability")
struct AssetDiskCacheAuthorityDurabilityTests {
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    // MARK: - (f) A fresh-root bootstrap that cannot be proven durable fails the clear fence

    @Test(
        """
        A fresh-root bootstrap whose durable write cannot be confirmed must surface from \
        removeAll() as clearFenceNotDurable -- never as a silently-successful clear, and never \
        as some other typed case a caller that only special-cases the fence would mistake for \
        an ordinary persistence hiccup.
        """
    )
    func freshRootBootstrapFailureMapsToClearFenceNotDurable() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            // Fails the root-authority bootstrap's own durable writes,
            // before this instance has ever initialized the root.
            await cache.directoryAccess.installFaultInjection(
                failSuffixes: [
                    SecureCacheDirectory.clearEpochFileName,
                    SecureCacheDirectory.rootInitMarkerFileName,
                ]
            )

            await #expect(throws: AssetError.self) {
                try await cache.removeAll()
            }
            do {
                try await cache.removeAll()
                Issue.record("A non-durable root bootstrap must never report a successful clear")
            } catch let error as AssetError {
                guard case .clearFenceNotDurable = error else {
                    Issue.record("Expected clearFenceNotDurable, got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - (g) Every atomic-write crash point yields old-or-new, never torn

    @Test(
        """
        Every crash point in the single canonical record's atomic write -- the temp write, the \
        rename, and the directory fsync that follows it -- leaves the durable record either \
        entirely at its previous value or entirely at its new one, never torn: a sibling \
        instance opened afterward always decodes a valid record, and a failed write never \
        advances the applied disposition.
        """
    )
    func atomicRecordWriteIsAlwaysAllOrNothingAtEveryCrashPoint() async throws {
        let recordSuffix = ".applied"
        let faults: [(label: String, install: (SecureCacheDirectory) -> Void)] = [
            ("temp write", { $0.installFaultInjection(failSuffixes: [recordSuffix]) }),
            ("rename", { $0.installFaultInjection(failRenameToSuffixes: [recordSuffix]) }),
            (
                "directory fsync after rename",
                { $0.installFaultInjection(failFsyncAfterRenameSuffixes: [recordSuffix]) }
            ),
        ]

        for fault in faults {
            try await fixtures.withScratchDirectory { directory in
                let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
                let cacheKey = try fixtures.key("01001")

                let token = try await fixtures.issuedToken(from: cache, for: cacheKey)
                let payload = Data([1, 1, 1])
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: fixtures.metadata(for: cacheKey, payload: payload),
                    token: token
                )
                let settled = try await cache.currentKeyRecord(for: cacheKey)
                #expect(settled.disposition.kind == .content)

                await fault.install(cache.directoryAccess)
                // Every subsequent authority write for this key now
                // fails at exactly this crash point.
                await #expect(throws: AssetError.self) {
                    _ = try await cache.beginIssuance(for: cacheKey)
                }
                await cache.directoryAccess.installFaultInjection()

                // A brand-new instance over the same directory -- a
                // restart, or an independent process -- must decode a
                // complete, valid record, and it must be either the
                // pre-fault value or a fully-formed newer one. It can
                // never be a truncated fragment.
                let sibling = try AssetDiskCache(directory: directory, limits: fixtures.limits())
                let recovered = try await sibling.currentKeyRecord(for: cacheKey)
                let landedWholly = recovered.issuedAuthorityID != settled.issuedAuthorityID
                    && recovered.transitionRevision == settled.transitionRevision + 1
                    && recovered.disposition == settled.disposition
                #expect(
                    recovered == settled || landedWholly,
                    "\(fault.label): recovery must see the record wholly old or wholly new"
                )
                // Whichever of the two landed, the *applied* disposition
                // never advanced: a failed issuance mutates only the
                // issued identifier, never the content it authorizes.
                #expect(recovered.disposition == settled.disposition)
                #expect(
                    try await sibling.get(cacheKey) != nil,
                    "\(fault.label): the pre-fault publication must remain intact"
                )

                // Issuance works normally again once the fault clears,
                // proving the failed write left no poisoned state behind.
                let resumed = try await sibling.beginIssuance(for: cacheKey)
                #expect(resumed.authorityID != token.diskAuthorityID)
                #expect(resumed.authorityID != recovered.issuedAuthorityID)
                #expect(resumed.revision == recovered.transitionRevision + 1)
            }
        }
    }
}
