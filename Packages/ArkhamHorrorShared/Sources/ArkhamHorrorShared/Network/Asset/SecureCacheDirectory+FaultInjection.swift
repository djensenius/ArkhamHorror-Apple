import Foundation

/// Test-only fault-injection state for ``SecureCacheDirectory``, isolated
/// into its own lock-backed type (rather than plain stored properties on
/// `SecureCacheDirectory` itself) so a test can install it and read its
/// call counter from outside the actor that owns the surrounding
/// ``AssetDiskCache`` without any additional synchronization of its own —
/// mirroring `AssetDiskCacheTests.swift`'s pre-existing `AtomicCallCounter`
/// pattern for the same reason (reading a plain property on a value just
/// handed to an actor-isolated initializer trips the compiler's
/// region-isolation "sending" analysis even when every real call site
/// awaits the actor first and so never actually races).
///
/// Split out of `SecureCacheDirectory.swift` purely to stay under this
/// package's `file_length` convention.
final class FaultInjectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failSuffixes: Set<String> = []
    private var _failPrefixes: Set<String> = []
    private var _failRemoveSuffixes: Set<String> = []
    private var _failRemovePrefixes: Set<String> = []
    private var _listNamesFailuresRemaining = 0
    private var _listNamesCallCount = 0
    private var _failFsyncAfterRenameSuffixes: Set<String> = []
    private var _lastRenamedFinalName: String?
    private var _failAttributesSuffixes: Set<String> = []
    private var _failNextRootFsyncCount = 0
    private var _failReaddirAfterEntryCount: Int?
    private var _failRenameToSuffixes: Set<String> = []

    var failSuffixes: Set<String> {
        get { lock.withLock { _failSuffixes } }
        set { lock.withLock { _failSuffixes = newValue } }
    }

    var failPrefixes: Set<String> {
        get { lock.withLock { _failPrefixes } }
        set { lock.withLock { _failPrefixes = newValue } }
    }

    var failRemoveSuffixes: Set<String> {
        get { lock.withLock { _failRemoveSuffixes } }
        set { lock.withLock { _failRemoveSuffixes = newValue } }
    }

    var failRemovePrefixes: Set<String> {
        get { lock.withLock { _failRemovePrefixes } }
        set { lock.withLock { _failRemovePrefixes = newValue } }
    }

    var listNamesFailuresRemaining: Int {
        get { lock.withLock { _listNamesFailuresRemaining } }
        set { lock.withLock { _listNamesFailuresRemaining = newValue } }
    }

    var listNamesCallCount: Int {
        lock.withLock { _listNamesCallCount }
    }

    /// Matched against the *final* name most recently passed to
    /// ``SecureCacheDirectory/rename(from:to:)`` — lets a test fail only
    /// the directory `fsync` that immediately follows a *specific*
    /// rename (e.g. the metadata pointer's, but not the payload
    /// generation's), reproducing exactly "the rename itself already
    /// succeeded, but confirming its durability did not" without also
    /// perturbing unrelated renames earlier in the same call.
    var failFsyncAfterRenameSuffixes: Set<String> {
        get { lock.withLock { _failFsyncAfterRenameSuffixes } }
        set { lock.withLock { _failFsyncAfterRenameSuffixes = newValue } }
    }

    /// `tempName` is always `.tmp`-suffixed (see
    /// ``SecureCacheDirectory/writeTempAndFsync(tempName:data:)``), so
    /// suffixes/prefixes are matched against the *stripped* final name
    /// (without the trailing `.tmp`) to line up with the target filename a
    /// test actually cares about, exactly as `FailingFileManager` matched
    /// against `moveItem`'s destination URL.
    ///
    /// A *prefix*-based match deliberately excludes the per-key
    /// issuance/applied ticket counter files (`.gen`/`.applied` — see
    /// `AssetDiskCache+WriteGeneration.swift`): those share a key's
    /// content-file prefix purely as an implementation detail, but a
    /// test that installs `failPrefixes: ["<keyHash>."]` to model "this
    /// key's *content* persistence is failing" means the payload/
    /// metadata write, not this key's internal issue-order bookkeeping —
    /// conflating the two would make an ordinary, narrowly-scoped
    /// best-effort-disk-failure scenario also fail durable ticket
    /// issuance itself, which is a categorically different scenario a
    /// test must opt into explicitly via `failSuffixes: [".gen"]`/
    /// `[".applied"]` instead.
    func shouldFailTempWrite(tempName: String) -> Bool {
        let strippedName = tempName.hasSuffix(".tmp") ? String(tempName.dropLast(4)) : tempName
        return lock.withLock {
            _failSuffixes.contains { strippedName.hasSuffix($0) }
                || (!strippedName.hasSuffix(".gen") && !strippedName.hasSuffix(".applied")
                    && _failPrefixes.contains { strippedName.hasPrefix($0) })
        }
    }

    /// Independent of `shouldFailTempWrite`: `name` here is already the
    /// exact, final entry name `remove(name:)` was called with (never a
    /// `.tmp` name), so no suffix-stripping is needed.
    func shouldFailRemove(name: String) -> Bool {
        lock.withLock {
            _failRemoveSuffixes.contains { name.hasSuffix($0) }
                || _failRemovePrefixes.contains { name.hasPrefix($0) }
        }
    }

    func recordListNamesCallAndCheckFault() throws {
        let shouldFail: Bool = lock.withLock {
            _listNamesCallCount += 1
            guard _listNamesFailuresRemaining > 0 else { return false }
            _listNamesFailuresRemaining -= 1
            return true
        }
        guard !shouldFail else {
            throw AssetError.cachePersistenceFailed("injected fault: listNames")
        }
    }

    /// Records the final name of a rename that just succeeded, for
    /// attribution by the *next* ``shouldFailNextDirectoryFsync()`` call
    /// only — cleared unconditionally by that call (whether or not it
    /// actually injects a failure) so a later, unrelated `fsync` can never
    /// be mistakenly attributed to a stale prior rename.
    func recordRename(finalName: String) {
        lock.withLock { _lastRenamedFinalName = finalName }
    }

    func shouldFailNextDirectoryFsync() -> Bool {
        lock.withLock {
            defer { _lastRenamedFinalName = nil }
            guard let name = _lastRenamedFinalName else { return false }
            return _failFsyncAfterRenameSuffixes.contains { name.hasSuffix($0) }
        }
    }

    /// Matched against the exact name passed to
    /// ``SecureCacheDirectory/attributes(name:)`` — simulates a genuine
    /// `fstatat` failure (permission/I/O/etc, as opposed to the file
    /// simply not existing) for a specific entry name, so a test can
    /// prove ``AssetDiskCache/areDiskWritesDisabledLocked()`` fails
    /// *closed* (treats an unconfirmable check the same as "marker
    /// present") rather than silently collapsing the failure into
    /// "marker absent".
    var failAttributesSuffixes: Set<String> {
        get { lock.withLock { _failAttributesSuffixes } }
        set { lock.withLock { _failAttributesSuffixes = newValue } }
    }

    func shouldFailAttributes(name: String) -> Bool {
        lock.withLock {
            _failAttributesSuffixes.contains { name.hasSuffix($0) }
        }
    }

    /// Unconditionally fails the next `N` calls to
    /// ``SecureCacheDirectory/fsyncRootDirectory()``, regardless of
    /// whether any rename preceded them — independent of
    /// ``failFsyncAfterRenameSuffixes``, which only fires when attributed
    /// to a specific just-renamed name. Lets a test fail a root `fsync`
    /// that follows plain `remove(name:)` calls (e.g.
    /// ``AssetDiskCache/removeAll()``'s own final directory `fsync`),
    /// which never goes through `rename` at all.
    var failNextRootFsyncCount: Int {
        get { lock.withLock { _failNextRootFsyncCount } }
        set { lock.withLock { _failNextRootFsyncCount = newValue } }
    }

    func shouldFailRootFsyncUnconditionally() -> Bool {
        lock.withLock {
            guard _failNextRootFsyncCount > 0 else { return false }
            _failNextRootFsyncCount -= 1
            return true
        }
    }

    /// Simulates ``SecureCacheDirectory/listNames()``'s underlying
    /// `readdir` loop hitting a genuine I/O error after enumerating
    /// exactly `count` real entries -- as opposed to
    /// ``listNamesFailuresRemaining``, which fails the *entire* call
    /// before it ever opens the directory stream at all. This lets a test
    /// prove the errno-checked `readdir` loop (see ``listNames()``'s own
    /// doc comment) actually distinguishes a genuine mid-enumeration
    /// failure from end-of-directory, rather than merely exercising the
    /// coarser "the whole call failed" path every other `listNames`
    /// fault-injection case already covers.
    var failReaddirAfterEntryCount: Int? {
        get { lock.withLock { _failReaddirAfterEntryCount } }
        set { lock.withLock { _failReaddirAfterEntryCount = newValue } }
    }

    func shouldFailReaddirAfterEntryCount(currentCount: Int) -> Bool {
        lock.withLock {
            guard let threshold = _failReaddirAfterEntryCount else { return false }
            return currentCount >= threshold
        }
    }

    /// Matched against the *final* (destination) name passed to
    /// ``SecureCacheDirectory/rename(from:to:)`` — fails the `renameat`
    /// syscall itself, before it ever runs, independent of whether a
    /// temp file exists at the source name. Deliberately distinct from
    /// ``failFsyncAfterRenameSuffixes`` (which lets the rename itself
    /// succeed and only fails the *durability* confirmation after it):
    /// this instead reproduces "the rename that would publish this
    /// destination name never happens at all", so no file — stub or
    /// otherwise — ever ends up present at `finalName` on disk, unlike
    /// ``shouldFailTempWrite(tempName:)``'s injected failure path, which
    /// deliberately leaves a stub temp file behind to model a torn write.
    var failRenameToSuffixes: Set<String> {
        get { lock.withLock { _failRenameToSuffixes } }
        set { lock.withLock { _failRenameToSuffixes = newValue } }
    }

    func shouldFailRename(finalName: String) -> Bool {
        lock.withLock {
            _failRenameToSuffixes.contains { finalName.hasSuffix($0) }
        }
    }
}
