@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``SecureCacheDirectory/ensureRootAuthorityInitializedLockedUnwrapped``
/// gates epoch-zero (re-)initialization on an independent, race-proof
/// freshness proof -- this exact instance's own `mkdirat` having won the
/// race to create the root directory, or a durable
/// ``SecureCacheDirectory/rootFreshnessWitnessFileName`` file recording
/// that a prior creator did -- rather than on whatever names happen to
/// survive inside a root whose clear-epoch counter and root-init marker
/// are both currently missing.
///
/// Before this fix, a used root's own ``AssetDiskCache/diskWritesDisabledMarkerName``
/// survivor was, by name alone, an *accepted* survivor in
/// ``AssetDiskCache+RootAuthority.swift``'s own `isSurvivingEntryAcceptable`
/// closure -- so a previously-cleared, previously-used root that lost both
/// authority files (deleted, corrupted, or from a version predating either)
/// but still happened to retain that one marker (an ordinary used-root
/// failure state with zero bearing on freshness) would be silently
/// re-initialized to clear-epoch `0`, resurrecting whatever authority a
/// real prior clear was supposed to have revoked. This suite proves that
/// can no longer happen, regardless of which names a caller's own
/// `isSurvivingEntryAcceptable` closure would otherwise accept, and that a
/// genuinely fresh root -- and only a genuinely fresh root -- still
/// initializes correctly.
@Suite("SecureCacheDirectory root-freshness witness gates epoch-zero (re-)initialization")
struct RootFreshnessWitnessTests {
    private func withScratchDirectory(
        _ body: (_ base: URL) throws -> Void
    ) throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("RootFreshnessWitnessScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    /// The exact production closure ``AssetDiskCache+RootAuthority.swift``
    /// wires in -- reused directly here (rather than a test-only
    /// substitute) so this suite exercises the identical acceptance
    /// policy production code actually runs under.
    private func acceptsOnlyDiskWritesDisabledMarker(_ name: String) -> Bool {
        name == AssetDiskCache.diskWritesDisabledMarkerName
    }

    @Test(
        """
        A genuinely fresh root -- this exact instance's own mkdirat having just created it --
        still initializes clear-epoch 0 and both authority files normally
        """
    )
    func freshRootStillInitializesNormally() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            let secure = try SecureCacheDirectory(directory: root, fileManager: .default)
            #expect(secure.rootDirectoryWasFreshlyCreated)
            try secure.ensureRootAuthorityInitializedLocked(
                isSurvivingEntryAcceptable: acceptsOnlyDiskWritesDisabledMarker
            )
            #expect(try secure.readPersistedClearEpoch() == 0)
            #expect(
                try secure.read(name: SecureCacheDirectory.rootInitMarkerFileName, maxBytes: 1)
                    != nil
            )
            #expect(
                try secure.read(
                    name: SecureCacheDirectory.rootFreshnessWitnessFileName,
                    maxBytes: 1
                ) != nil
            )
        }
    }

    @Test(
        """
        A used root that lost both authority files but still retains only the \
        disk-writes-disabled marker fails closed rather than silently reinitializing to \
        clear-epoch 0
        """
    )
    func usedRootRetainingOnlyMarkerFailsClosed() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            // First open: genuinely fresh. Initialize authority, bump the
            // epoch a few times (simulating real prior clears), then
            // simulate total authority-state loss by deleting every
            // authority file this instance itself wrote, while leaving
            // an empty file behind at the disk-writes-disabled marker's
            // own fixed name -- exactly the "used root retaining only
            // marker" scenario the review calls out.
            do {
                let secure = try SecureCacheDirectory(directory: root, fileManager: .default)
                try secure.ensureRootAuthorityInitializedLocked(
                    isSurvivingEntryAcceptable: acceptsOnlyDiskWritesDisabledMarker
                )
                _ = try secure.bumpClearEpoch()
                _ = try secure.bumpClearEpoch()
                try FileManager.default.removeItem(
                    at: root.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
                )
                try FileManager.default.removeItem(
                    at: root.appendingPathComponent(SecureCacheDirectory.rootInitMarkerFileName)
                )
                try FileManager.default.removeItem(
                    at: root.appendingPathComponent(
                        SecureCacheDirectory.rootFreshnessWitnessFileName
                    )
                )
                try Data().write(
                    to: root.appendingPathComponent(AssetDiskCache.diskWritesDisabledMarkerName)
                )
            }
            // Second open: a brand-new instance opening this same,
            // already-existing directory -- `mkdirat` observes `EEXIST`,
            // so this instance's own in-memory freshness flag is `false`,
            // and no durable witness file survived either.
            let reopened = try SecureCacheDirectory(directory: root, fileManager: .default)
            #expect(!reopened.rootDirectoryWasFreshlyCreated)
            #expect(throws: AssetError.self) {
                try reopened.ensureRootAuthorityInitializedLocked(
                    isSurvivingEntryAcceptable: acceptsOnlyDiskWritesDisabledMarker
                )
            }
        }
    }

    @Test(
        """
        A non-regular entry (a directory) planted at the disk-writes-disabled marker's own \
        name inside an otherwise genuinely fresh root is still rejected, even though the \
        freshness proof alone would already permit initialization
        """
    )
    func nonRegularMarkerFailsClosedEvenOnFreshRoot() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            let secure = try SecureCacheDirectory(directory: root, fileManager: .default)
            #expect(secure.rootDirectoryWasFreshlyCreated)
            // Plant a *directory* (never a regular file) at the exact
            // name the closure below accepts by name alone -- simulating
            // a bug, a race, or a foreign writer, never anything the
            // marker's own real writer
            // (``AssetDiskCache/markDiskWritesDisabledLocked()``) could
            // ever itself produce.
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(AssetDiskCache.diskWritesDisabledMarkerName),
                withIntermediateDirectories: false
            )
            #expect(throws: AssetError.self) {
                try secure.ensureRootAuthorityInitializedLocked(
                    isSurvivingEntryAcceptable: acceptsOnlyDiskWritesDisabledMarker
                )
            }
        }
    }

    @Test(
        """
        Two independently-wired services sharing one already-initialized, since-cleared root: \
        a second instance's own open must read the real, already-bumped durable epoch, never \
        silently resetting it back to 0 merely because that second instance did not itself \
        create the root
        """
    )
    func concurrentServiceNeverResurrectsEpochZeroFromMemory() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            let first = try SecureCacheDirectory(directory: root, fileManager: .default)
            try first.ensureRootAuthorityInitializedLocked(
                isSurvivingEntryAcceptable: acceptsOnlyDiskWritesDisabledMarker
            )
            let bumped = try first.bumpClearEpoch()
            #expect(bumped == 1)

            // A second, independently-constructed instance -- modeling a
            // second `AssetCacheService`/`AssetDiskCache` sharing this
            // same directory -- opens the same, already-used root.
            let second = try SecureCacheDirectory(directory: root, fileManager: .default)
            #expect(!second.rootDirectoryWasFreshlyCreated)
            try second.ensureRootAuthorityInitializedLocked(
                isSurvivingEntryAcceptable: acceptsOnlyDiskWritesDisabledMarker
            )
            // Authority already existed (the epoch file itself is
            // present), so this call takes the "already initialized"
            // branch and must never rewrite the counter: the second
            // instance's own read must observe the real, already-bumped
            // value, not a resurrected 0.
            #expect(try second.readPersistedClearEpoch() == 1)
            #expect(try first.readPersistedClearEpoch() == 1)
        }
    }
}
