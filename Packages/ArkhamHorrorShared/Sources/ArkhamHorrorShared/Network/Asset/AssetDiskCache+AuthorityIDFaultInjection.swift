import Foundation

/// Test-only fault-injection state for the ``AuthorityID`` source
/// ``AssetDiskCache/issueAuthorityLocked(for:)`` mints from, isolated
/// into its own lock-backed type exactly the way
/// ``FaultInjectionState`` already is for ``SecureCacheDirectory``'s own
/// I/O faults (see `SecureCacheDirectory+FaultInjection.swift`), and for
/// the same reason: a test installs it and reads its call counter from
/// outside the actor that owns the surrounding ``AssetDiskCache``,
/// without needing any synchronization of its own.
///
/// **Why this exists at all.** A 128-bit CSPRNG value colliding with
/// anything is a `2^-128`-per-draw event, so the collision-handling and
/// hard-RNG-failure branches of issuance can never be reached by
/// sampling real randomness, however many samples a test takes. They are
/// still real code paths that must terminate, fail typed, and write
/// nothing — so the only honest way to test them is to force the exact
/// values (or the exact failure) they are written to handle.
///
/// Held per ``AssetDiskCache`` instance rather than as a process-wide
/// static, so a forced value queued by one test can never be consumed by
/// an unrelated cache instance running at the same time.
final class AuthorityIDFaultInjectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _forcedIdentifiers: [AuthorityID] = []
    private var _repeatsFinalForcedIdentifier = false
    private var _forcedFailuresRemaining = 0
    private var _mintCallCount = 0

    /// Consumed in order, one per mint attempt, before falling back to
    /// the real CSPRNG once the queue is empty.
    var forcedIdentifiers: [AuthorityID] {
        get { lock.withLock { _forcedIdentifiers } }
        set { lock.withLock { _forcedIdentifiers = newValue } }
    }

    /// When `true`, the last entry of ``forcedIdentifiers`` is returned
    /// for every attempt after the queue would otherwise be exhausted —
    /// the shape needed to prove a *permanently* colliding source is
    /// bounded by the retry limit rather than retried forever, without a
    /// test having to guess and hard-code that limit into the length of
    /// the queue it installs.
    var repeatsFinalForcedIdentifier: Bool {
        get { lock.withLock { _repeatsFinalForcedIdentifier } }
        set { lock.withLock { _repeatsFinalForcedIdentifier = newValue } }
    }

    /// Simulates the underlying `SecRandomCopyBytes` call itself
    /// reporting a hard failure for this many subsequent attempts — the
    /// one condition ``AuthorityID/random()`` refuses to paper over with
    /// a weaker source of randomness.
    var forcedFailuresRemaining: Int {
        get { lock.withLock { _forcedFailuresRemaining } }
        set { lock.withLock { _forcedFailuresRemaining = newValue } }
    }

    /// Every mint attempt made through this state, forced or not — so a
    /// test can prove the bounded retry loop stopped at its documented
    /// bound rather than spinning.
    var mintCallCount: Int {
        lock.withLock { _mintCallCount }
    }

    /// The identifier this attempt must use, or `nil` to fall through to
    /// the real CSPRNG. Throws the same typed failure a genuine
    /// `SecRandomCopyBytes` non-success produces.
    func nextForcedIdentifier() throws -> AuthorityID? {
        try lock.withLock {
            _mintCallCount += 1
            if _forcedFailuresRemaining > 0 {
                _forcedFailuresRemaining -= 1
                throw AssetError.cachePersistenceFailed(
                    "injected fault: cache authority identifier randomness unavailable"
                )
            }
            guard !_forcedIdentifiers.isEmpty else { return nil }
            if _forcedIdentifiers.count == 1, _repeatsFinalForcedIdentifier {
                return _forcedIdentifiers[0]
            }
            return _forcedIdentifiers.removeFirst()
        }
    }
}

/// Test-only installer/accessor, mirroring
/// `SecureCacheDirectory.installFaultInjection(...)` -- the same
/// lock-protected, per-instance shape, installed the same way.
extension AssetDiskCache {
    /// Installs (or, called with no arguments, clears) deterministic
    /// control over this instance's authority-identifier source.
    func installAuthorityIDFaultInjection(
        forcedIdentifiers: [AuthorityID] = [],
        repeatsFinalForcedIdentifier: Bool = false,
        forcedFailuresRemaining: Int = 0
    ) {
        authorityIDFaultState.forcedIdentifiers = forcedIdentifiers
        authorityIDFaultState.repeatsFinalForcedIdentifier = repeatsFinalForcedIdentifier
        authorityIDFaultState.forcedFailuresRemaining = forcedFailuresRemaining
    }

    /// Test-only: how many mint attempts this instance has made.
    var authorityIDMintCallCount: Int {
        authorityIDFaultState.mintCallCount
    }
}
