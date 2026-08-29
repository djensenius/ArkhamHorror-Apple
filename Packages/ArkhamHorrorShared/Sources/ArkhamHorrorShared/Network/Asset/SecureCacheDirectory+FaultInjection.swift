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

    /// `tempName` is always `.tmp`-suffixed (see
    /// ``SecureCacheDirectory/writeTempAndFsync(tempName:data:)``), so
    /// suffixes/prefixes are matched against the *stripped* final name
    /// (without the trailing `.tmp`) to line up with the target filename a
    /// test actually cares about, exactly as `FailingFileManager` matched
    /// against `moveItem`'s destination URL.
    func shouldFailTempWrite(tempName: String) -> Bool {
        let strippedName = tempName.hasSuffix(".tmp") ? String(tempName.dropLast(4)) : tempName
        return lock.withLock {
            _failSuffixes.contains { strippedName.hasSuffix($0) }
                || _failPrefixes.contains { strippedName.hasPrefix($0) }
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
}
