@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for `AssetDiskCache`'s disk-*writes*-disabled fail-closed
/// mechanism (see `AssetDiskCache+Tombstone.swift`'s
/// `markDiskWritesDisabledLocked()`/`AssetDiskCache.swift`'s
/// `requireDiskWritesEnabledLocked()`): a persistently-unenumerable
/// directory, an unreadable stray file's size, or an accounted total that
/// still exceeds budget even after evicting everything evictable must
/// durably refuse *new* writes rather than silently accepting bytes into a
/// cache whose physical usage cannot be proven bounded. Split out of
/// `AssetDiskCacheQuotaTests.swift`/`AssetDiskCacheOrphanQuotaTests.swift`
/// purely to stay under SwiftLint's `file_length`.
extension AssetDiskCacheTests {
    /// Deliberately tight water marks, mirroring
    /// `AssetDiskCacheOrphanQuotaTests.orphanQuotaTestLimits()`'s style,
    /// so a single small entry alone would never trigger eviction —
    /// isolating every assertion below to the write-disabled mechanism
    /// itself, not ordinary LRU pressure.
    func writeDisabledTestLimits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        )
    }

    @Test(
        """
        A directory listing that persistently fails to enumerate durably disables new disk \
        writes -- rather than silently accepting bytes into a cache whose total physical usage \
        can no longer be determined at all -- and a brand-new AssetDiskCache instance opened \
        over the same directory (simulating a restart) still refuses to accept a write, proving \
        the disabled state survives process restart rather than only living in memory
        """
    )
    func persistentListingFailureDisablesWritesDurablyAcrossRestart() async throws {
        try await withScratchDirectory { directory in
            let firstCache = try AssetDiskCache(
                directory: directory,
                limits: writeDisabledTestLimits()
            )
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await firstCache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            // Fail every subsequent `listNames()` call from here on, so
            // `evictIfNeeded()`'s own budget pass can never succeed again
            // for this actor instance.
            await firstCache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 999)

            // Proactive locked accounting now runs before every write, so
            // this write's own *pre-write* gate hits the persistent
            // listing failure and is rejected -- not merely a later one.
            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await firstCache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }

            // The *next* write attempt's own pre-write gate now finds
            // writes already disabled, attempts one recovery pass (which
            // fails identically, since the fault is still installed), and
            // must refuse to proceed.
            let thirdKey = try key("01003")
            let thirdPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await firstCache.set(
                    thirdKey,
                    payload: thirdPayload,
                    metadata: metadata(for: thirdKey, payload: thirdPayload)
                )
            }

            // A brand-new instance over the same directory, simulating a
            // process restart, with the exact same underlying condition
            // still present (e.g. a still-unenumerable directory --
            // fault-injection state is per-instance, not global, so a
            // real restart's own equivalent underlying failure must be
            // re-supplied here) must still refuse writes: the durable
            // on-disk marker -- checked before this fresh instance's own
            // first recovery attempt even runs -- is what is actually
            // being enforced, not any single process's in-memory state.
            let restartedCache = try AssetDiskCache(
                directory: directory,
                limits: writeDisabledTestLimits()
            )
            await restartedCache.directoryAccess.installFaultInjection(
                listNamesFailuresRemaining: 999
            )
            let fourthKey = try key("01004")
            let fourthPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await restartedCache.set(
                    fourthKey,
                    payload: fourthPayload,
                    metadata: metadata(for: fourthKey, payload: fourthPayload)
                )
            }
        }
    }

    @Test(
        """
        Once a persistent listing failure clears (a transient fault resolves), the very next \
        write attempt's own recovery pass proves the budget again and lets that write -- and \
        every later one -- succeed normally, rather than the disabled marker persisting forever \
        once conditions have actually improved
        """
    )
    func clearedListingFailureReenablesWritesOnNextAttempt() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: writeDisabledTestLimits())
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            await cache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 999)
            // Proactive locked accounting runs before this write is even
            // attempted, so this call itself is now rejected (rather than
            // succeeding and only disabling some later write).
            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }

            // Confirms writes are indeed disabled at this point.
            let thirdKey = try key("01003")
            let thirdPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    thirdKey,
                    payload: thirdPayload,
                    metadata: metadata(for: thirdKey, payload: thirdPayload)
                )
            }

            // Clearing the fault entirely (no more injected failures)
            // must let the very next write's own pre-write recovery pass
            // observe a clean listing again and re-enable writes.
            await cache.directoryAccess.installFaultInjection()
            let fourthKey = try key("01004")
            let fourthPayload = Data(count: 100)
            try await cache.set(
                fourthKey,
                payload: fourthPayload,
                metadata: metadata(for: fourthKey, payload: fourthPayload)
            )
            let fetched = try await cache.get(fourthKey)
            #expect(fetched != nil, "A write after the fault clears must succeed and be servable")
        }
    }

    @Test(
        """
        A stray cache-owned file (e.g. a durable tombstone or the disabled marker itself) whose \
        own size cannot be determined disables new writes exactly like an unenumerable \
        directory listing -- physical usage is not fully known either way, and must never be \
        silently under-counted as though the unreadable file contributed zero bytes
        """
    )
    func unreadableStrayFileSizeDisablesWrites() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: writeDisabledTestLimits())
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            // A durable tombstone file is exactly the kind of stray,
            // non-`.bin`/`.meta.json`/`.tmp` cache-owned file this
            // mechanism must still account for; failing `attributes(name:)`
            // for it simulates an `fstatat` failure (permission/I/O) on
            // that exact stray file.
            let tombstoneName = "\(firstKey.digestHex).tombstone"
            try Data("1".utf8).write(to: directory.appendingPathComponent(tombstoneName))
            // The exact full filename (not merely the generic
            // `.tombstone` suffix) is used as the fault pattern: it still
            // matches via `hasSuffix`, but -- since every key's tombstone
            // name is prefixed by that key's own distinct 64-character
            // SHA-256 hash -- can never also match a *different* key's
            // (here, `secondKey`'s) unrelated, nonexistent tombstone
            // check, which a bare `.tombstone` suffix would.
            await cache.directoryAccess.installFaultInjection(
                failAttributesSuffixes: [tombstoneName]
            )

            // This write's own *pre-write* proactive accounting pass is
            // the one that actually encounters the unreadable stray file
            // and marks writes disabled -- the call itself must now be
            // rejected rather than succeeding and only affecting some
            // later write.
            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }

            let thirdKey = try key("01003")
            let thirdPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    thirdKey,
                    payload: thirdPayload,
                    metadata: metadata(for: thirdKey, payload: thirdPayload)
                )
            }
        }
    }

    @Test(
        """
        A persistent per-entry removal failure that leaves accounted usage over the high water \
        mark even after every evictable entry has been attempted disables new writes, rather \
        than reporting the pass as successful merely because it ran to completion
        """
    )
    func persistentEvictionFailureLeavingOverBudgetDisablesWrites() async throws {
        try await withScratchDirectory { directory in
            // diskBudgetBytes=3000 -> highWaterMarkDiskBytes=1800, lowWaterMarkDiskBytes=900.
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 1_000_000,
                diskBudgetBytes: 3000,
                highWaterMarkRatio: 0.6,
                lowWaterMarkRatio: 0.3
            )
            let cache = try AssetDiskCache(directory: directory, limits: limits)

            // Small enough alone to stay comfortably under the high
            // water mark, so it is never itself evicted by this first
            // write's own (fault-free) `evictIfNeeded()` pass.
            let firstKey = try key("01001")
            let firstPayload = Data(count: 500)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            // Fail every `.bin` removal from here on, so no entry's
            // payload can ever actually be reclaimed once eviction is
            // triggered.
            await cache.directoryAccess.installFaultInjection(failRemoveSuffixes: [".bin"])

            // Large enough that, combined with the first entry, total
            // accounted usage exceeds the high water mark and forces an
            // eviction attempt -- this `set` call itself still succeeds
            // (evictIfNeeded's own failure to reclaim never throws back
            // to the caller that just successfully published), but must
            // leave the whole cache's writes durably disabled afterward.
            let secondKey = try key("01002")
            let secondPayload = Data(count: 1500)
            try await cache.set(
                secondKey,
                payload: secondPayload,
                metadata: metadata(for: secondKey, payload: secondPayload)
            )

            let thirdKey = try key("01003")
            let thirdPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    thirdKey,
                    payload: thirdPayload,
                    metadata: metadata(for: thirdKey, payload: thirdPayload)
                )
            }
        }
    }

    @Test(
        """
        A write-disable *marker commit itself* failing (the durable temp-write/rename that \
        persists ".disk-writes-disabled" never actually succeeds, e.g. because the filesystem \
        is momentarily full or read-only right at that exact moment) must still leave this same \
        process instance fail-closed for every later write -- the in-memory local flag, set \
        before that doomed commit is even attempted, is what actually enforces this, since the \
        durable marker file genuinely does not exist on disk to be checked by a later call
        """
    )
    func failedMarkerCommitStillDisablesWritesInProcess() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: writeDisabledTestLimits())
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            // Forces `evictIfNeeded()`'s fail-closed branch (an
            // unenumerable directory), *and* separately fails the marker
            // commit's own publishing rename, so the durable
            // ".disk-writes-disabled" marker this call attempts to write
            // never actually lands on disk at all -- simulating exactly
            // the "marker commit itself failed" scenario this fix
            // targets, as opposed to every other test in this file where
            // the marker commit succeeds and only the *budget check*
            // fails. `failRenameToSuffixes` (rather than `failSuffixes`,
            // the temp-write fault) is used deliberately: the temp-write
            // fault path intentionally leaves a stub file behind to model
            // a torn write, and this cache's `markDiskWritesDisabledLocked()`
            // unconditionally attempts its rename afterward regardless of
            // whether the temp write itself reported success -- so a
            // temp-write-only fault would still let that stub get renamed
            // into place, leaving a marker file on disk despite the
            // "failure". Failing the rename itself instead guarantees no
            // file of any kind ever ends up at the final marker name.
            await cache.directoryAccess.installFaultInjection(
                listNamesFailuresRemaining: 999,
                failRenameToSuffixes: [AssetDiskCache.diskWritesDisabledMarkerName]
            )

            // This write's own *pre-write* proactive accounting pass hits
            // the unenumerable listing, attempts to durably mark writes
            // disabled, and that attempt itself fails -- the write call
            // must now be rejected, since the in-memory local flag set
            // before the doomed marker commit is what enforces this.
            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }

            // The durable marker must genuinely be absent from disk --
            // proving any rejection below cannot possibly be coming from
            // a successfully-committed durable marker file.
            let markerExists = try await cache.secureDirectory.attributes(
                name: AssetDiskCache.diskWritesDisabledMarkerName
            ) != nil
            #expect(
                !markerExists,
                "The durable marker commit was injected to fail and must not exist on disk"
            )

            // The underlying listing failure deliberately stays installed
            // (re-asserted here alongside the marker failure, since
            // `installFaultInjection` resets every field to its default
            // on each call): without this fix, `requireDiskWritesEnabledLocked()`'s
            // *initial* disabled-check would consult only the (absent)
            // durable marker, find "not disabled", and return immediately
            // -- skipping its own fresh `evictIfNeeded()` recovery
            // attempt entirely and silently reopening writes even though
            // the real underlying problem was never actually resolved.
            // With this fix, the in-memory local flag correctly makes
            // that initial check still report "disabled", forcing a
            // fresh recovery attempt that (correctly) fails identically
            // and keeps the write rejected.
            await cache.directoryAccess.installFaultInjection(
                listNamesFailuresRemaining: 999,
                failRenameToSuffixes: [AssetDiskCache.diskWritesDisabledMarkerName]
            )

            let thirdKey = try key("01003")
            let thirdPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    thirdKey,
                    payload: thirdPayload,
                    metadata: metadata(for: thirdKey, payload: thirdPayload)
                )
            }
        }
    }
}
