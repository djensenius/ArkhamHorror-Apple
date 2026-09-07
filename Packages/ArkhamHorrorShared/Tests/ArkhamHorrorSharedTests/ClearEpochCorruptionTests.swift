@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``SecureCacheDirectory/readPersistedClearEpoch()`` (and its
/// callers, ``AssetDiskCache/currentClearEpoch()`` /
/// ``AssetCacheService/currentDurableClearEpoch()``) genuinely fail
/// closed on a corrupt or unparsable clear-epoch file, rather than
/// silently collapsing that read failure into the same `0` baseline a
/// clean "never cleared yet" miss produces.
///
/// Before this fix, `readPersistedClearEpoch()` wrapped its underlying
/// `read(...)` in `try?` and folded *every* failure -- a clean ENOENT
/// miss, a corrupt/foreign file, a wrong-owner or bounded-read violation
/// -- into the same `0` return value. That silently defeated the
/// documented fail-closed contract on
/// ``AssetCacheService/currentDurableClearEpoch()`` (`nil` on durable-read
/// failure, treated as "not authoritative" by every caller): a corrupt
/// epoch file could never actually produce that `nil`, so an instance
/// that could not durably read the shared clear epoch would incorrectly
/// treat itself as if no cross-instance clear had ever happened.
@Suite("SecureCacheDirectory clear-epoch fail-closed on read failure")
struct ClearEpochCorruptionTests {
    private func withScratchDirectory(
        _ body: (_ base: URL) throws -> Void
    ) throws {
        let baseParent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ClearEpochCorruptionScratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseParent,
            withIntermediateDirectories: true
        )
        let base = baseParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    private func withScratchDirectory(
        _ body: (_ base: URL) async throws -> Void
    ) async throws {
        // Deliberately still pre-creates `base` itself (unlike the sync
        // overload above): this file's own async-context tests write raw
        // garbage bytes directly at `base` *before* ever constructing a
        // `SecureCacheDirectory`/`AssetDiskCache`, which requires the
        // directory to already exist.
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ClearEpochCorruptionScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await body(base)
    }

    @Test(
        """
        A cache root, once its durable root authority has been initialized \
        (``SecureCacheDirectory/ensureRootAuthorityInitializedLocked()``), reads a safe \
        baseline clear epoch of 0
        """
    )
    func missingFileReadsZero() throws {
        try withScratchDirectory { base in
            let secure = try SecureCacheDirectory(directory: base, fileManager: .default)
            try secure.ensureRootAuthorityInitializedLocked()
            #expect(try secure.readPersistedClearEpoch() == 0)
        }
    }

    @Test("A corrupt (non-numeric) clear-epoch file throws rather than reading 0")
    func corruptContentsThrows() throws {
        try withScratchDirectory { base in
            let secure = try SecureCacheDirectory(directory: base, fileManager: .default)
            try Data("not-a-number".utf8).write(
                to: base.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
            )
            #expect(throws: AssetError.self) {
                try secure.readPersistedClearEpoch()
            }
        }
    }

    @Test("An empty clear-epoch file throws rather than reading 0")
    func emptyContentsThrows() throws {
        try withScratchDirectory { base in
            let secure = try SecureCacheDirectory(directory: base, fileManager: .default)
            try Data().write(
                to: base.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
            )
            #expect(throws: AssetError.self) {
                try secure.readPersistedClearEpoch()
            }
        }
    }

    @Test("A negative-looking clear-epoch file (a bare '-') throws rather than reading 0")
    func negativeSignOnlyThrows() throws {
        try withScratchDirectory { base in
            let secure = try SecureCacheDirectory(directory: base, fileManager: .default)
            try Data("-".utf8).write(
                to: base.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
            )
            #expect(throws: AssetError.self) {
                try secure.readPersistedClearEpoch()
            }
        }
    }

    @Test("A valid persisted clear-epoch value round-trips through readPersistedClearEpoch")
    func validValueRoundTrips() throws {
        try withScratchDirectory { base in
            let secure = try SecureCacheDirectory(directory: base, fileManager: .default)
            try secure.ensureRootAuthorityInitializedLocked()
            let bumped = try secure.bumpClearEpoch()
            #expect(bumped == 1)
            #expect(try secure.readPersistedClearEpoch() == 1)
        }
    }

    @Test(
        """
        AssetDiskCache.currentClearEpoch() propagates a corrupt clear-epoch file as a \
        thrown error rather than returning 0
        """
    )
    func diskCacheCurrentClearEpochPropagatesCorruption() async throws {
        try await withScratchDirectory { base in
            try Data("garbage".utf8).write(
                to: base.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
            )
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            let diskCache = try AssetDiskCache(directory: base, limits: limits)
            await #expect(throws: AssetError.self) {
                try await diskCache.currentClearEpoch()
            }
        }
    }

    @Test(
        """
        AssetCacheService.currentDurableClearEpoch() reports nil -- the documented \
        fail-closed signal -- when the underlying clear-epoch file is corrupt, rather \
        than silently reporting 0 as if no clear had ever happened
        """
    )
    func serviceCurrentDurableClearEpochIsNilOnCorruption() async throws {
        try await withScratchDirectory { base in
            try Data("garbage".utf8).write(
                to: base.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
            )
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            let diskCache = try AssetDiskCache(directory: base, limits: limits)
            let service = AssetCacheService(
                memoryCache: AssetMemoryCache(limits: limits),
                diskCache: diskCache,
                transport: FakeAssetTransport(),
                digest: FakeDigestLookup(),
                limits: limits
            )
            let epoch = await service.currentDurableClearEpoch()
            #expect(epoch == nil)
        }
    }
}
