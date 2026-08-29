import Foundation
import os

/// A thread-safe counter, independent of any actor or `@unchecked Sendable`
/// class hierarchy, used by ``FailingFileManager`` to let a test observe
/// how many times an overridden method was called after crossing an actor
/// boundary. Deliberately not a stored property directly on
/// `FailingFileManager` itself: reading a property on the *same* object
/// that was just handed to an actor-isolated initializer trips the
/// compiler's region-isolation "sending" analysis for a `FileManager`
/// subclass (its non-`Sendable` superclass' internal state cannot be
/// proven safe purely via `@unchecked Sendable` on the subclass), even
/// though every real call site here awaits the actor before ever reading
/// the count, and so never races. Capturing this small, genuinely
/// `Sendable`, lock-backed object as its own local reference — before
/// `FailingFileManager` itself is sent to the actor's initializer — sits
/// outside that region entirely and is unaffected by that limitation.
final class AtomicCallCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    func increment() {
        lock.withLock { $0 += 1 }
    }

    var value: Int {
        lock.withLock { $0 }
    }
}

/// A `FileManager` subclass that injects a deterministic failure into the
/// final rename step (`moveItem`) for paths whose name ends in any of
/// `failPathSuffixes`, leaving every other filesystem operation (including
/// the *payload's* own atomic write) untouched.
///
/// This exercises ``AssetDiskCache``'s atomic-write failure-recovery path
/// with a real, precisely-targeted filesystem failure, rather than a
/// fragile permissions/filesystem-layout trick that risks failing (or
/// succeeding) for reasons unrelated to the code path under test.
/// Not `private`: also reused by ``AssetCacheServiceTests``'s
/// disk-persistence-failure coverage (in
/// `AssetCacheServicePersistenceTests.swift`) to simulate a real,
/// precisely-targeted filesystem failure without a fragile
/// permissions/filesystem-layout trick.
final class FailingFileManager: FileManager, @unchecked Sendable {
    var failPathSuffixes: Set<String> = []
    /// Matched against a candidate URL's last path component via
    /// `hasPrefix`, rather than the whole path via `hasSuffix` above.
    /// Needed to target "any payload generation for this cache key"
    /// under the content-addressed `<keyHash>.<contentHash>.bin` payload
    /// naming scheme, where the content hash (and therefore the exact
    /// suffix) is not known ahead of a write.
    var failPathPrefixes: Set<String> = []
    /// The number of remaining `contentsOfDirectory` calls that should
    /// fail before subsequent calls succeed normally. Used to simulate a
    /// transient (not permanent) directory-listing failure.
    var contentsOfDirectoryFailuresRemaining = 0
    /// Every successful or failed `contentsOfDirectory` call increments
    /// this, regardless of `contentsOfDirectoryFailuresRemaining`. A
    /// caller that needs to observe this after handing `self` to an
    /// actor-isolated initializer must capture this object itself (e.g.
    /// `let counter = failingFileManager.contentsOfDirectoryCallCounter`)
    /// *before* doing so — see ``AtomicCallCounter``'s documentation.
    let contentsOfDirectoryCallCounter = AtomicCallCounter()

    private func shouldFail(_ url: URL) -> Bool {
        failPathSuffixes.contains { url.path.hasSuffix($0) }
            || failPathPrefixes.contains { url.lastPathComponent.hasPrefix($0) }
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldFail(dstURL) {
            throw NSError(domain: "FailingFileManagerTest", code: 1)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        contentsOfDirectoryCallCounter.increment()
        if contentsOfDirectoryFailuresRemaining > 0 {
            contentsOfDirectoryFailuresRemaining -= 1
            throw NSError(domain: "FailingFileManagerTest", code: 2)
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
