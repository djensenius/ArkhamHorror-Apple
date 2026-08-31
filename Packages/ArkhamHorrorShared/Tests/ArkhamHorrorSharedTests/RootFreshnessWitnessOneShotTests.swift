@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``SecureCacheDirectory/rootFreshnessWitnessFileName`` is a true
/// **one-shot initialization token**, never a permanent freshness proof --
/// closing the gap `RootFreshnessWitnessTests.swift` alone left open.
///
/// Before this fix, the witness file was written once (at this root's
/// very first creation) and never removed again, even across an
/// arbitrary number of later, genuine ``AssetDiskCache/removeAll()``
/// clears (which deliberately preserve it, exactly like the epoch counter
/// and root-init marker). If, after one or more real clears had already
/// durably advanced the clear epoch, some fault entirely external to this
/// package (an operator, a misbehaving neighbor process, or a partial
/// restore from an old backup) independently caused *both* the epoch
/// counter and the root-init marker to go missing while that stale
/// witness file happened to survive, ``ensureRootAuthorityInitializedLockedUnwrapped``
/// would still find the witness present and wrongly re-initialize this
/// root's authority back to epoch `0` -- reopening exactly the
/// resurrection window a delayed/old token from before the real clear(s)
/// could then exploit.
///
/// This suite proves two independent closures, both required together:
///
/// 1. The durable witness file itself is now consumed (removed) the very
///    first time completed authority (the counter + marker) is next
///    observed by *any* instance/process -- so by the time a real clear
///    has ever happened, the witness can no longer durably exist at all
///    for a later reopen to misuse.
/// 2. A same-process, same-instance residual this durable removal alone
///    cannot close (this instance's own ``SecureCacheDirectory/rootDirectoryWasFreshlyCreated``
///    is a `let`, fixed at `init` time and therefore permanently stale
///    the instant real authority is later externally lost) is separately
///    closed by the in-process ``SecureCacheDirectory/hasDurablyObservedRootAuthorityOnce``
///    latch, set the moment this exact instance first durably observes
///    real authority, and never cleared again.
@Suite("SecureCacheDirectory root-freshness witness is a one-shot initialization token")
struct RootFreshnessWitnessOneShotTests {
    private func withScratchDirectory(
        _ body: (_ base: URL) throws -> Void
    ) throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("RootFreshnessWitnessOneShotScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    private func witnessExists(at root: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                SecureCacheDirectory.rootFreshnessWitnessFileName
            ).path
        )
    }

    @Test(
        """
        Production state: a real clear already durably advanced the epoch, and this exact \
        long-lived instance's own in-process latch -- not a manually pre-deleted witness -- is \
        what stops a later, externally-caused loss of both authority files (with the witness \
        somehow reintroduced) from resurrecting epoch 0 for a delayed old token
        """
    )
    func sameInstanceLatchProtectsResurrectionAfterRealClearAndAuthorityLoss() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            let secure = try SecureCacheDirectory(directory: root, fileManager: .default)

            // A genuinely fresh root, initialized normally by this exact
            // instance -- never pre-deleting the witness by hand. This is
            // the only call in this test that observes the witness file
            // at all; every subsequent step models purely external state
            // changes this same long-lived instance never itself caused.
            try secure.ensureRootAuthorityInitializedLocked()
            #expect(try secure.readPersistedClearEpoch() == 0)
            #expect(secure.hasDurablyObservedRootAuthorityOnce)
            #expect(
                !witnessExists(at: root),
                """
                The witness must already be durably consumed the moment real authority (counter \
                + marker) was first observed, never surviving a real clear
                """
            )

            // A real clear: an old token captured epoch 0 above is now
            // stale the instant this commits.
            let bumped = try secure.bumpClearEpoch()
            #expect(bumped == 1)

            // Some fault entirely external to this package now
            // reintroduces the witness file (a legacy leftover restore,
            // a foreign writer, or simply a bug elsewhere) *and*
            // independently destroys both authority files -- the exact
            // "both missing, witness present" shape a bare durable check
            // alone cannot distinguish from a genuinely pristine root.
            try Data([0x01]).write(
                to: root.appendingPathComponent(SecureCacheDirectory.rootFreshnessWitnessFileName)
            )
            try FileManager.default.removeItem(
                at: root.appendingPathComponent(SecureCacheDirectory.clearEpochFileName)
            )
            try FileManager.default.removeItem(
                at: root.appendingPathComponent(SecureCacheDirectory.rootInitMarkerFileName)
            )

            // This exact instance -- the same one that already durably
            // observed real authority above -- must fail closed
            // unconditionally, via its own in-process latch, regardless
            // of the reintroduced witness or `rootDirectoryWasFreshlyCreated`
            // (permanently `true` for this instance's whole lifetime).
            #expect(throws: AssetError.self) {
                try secure.ensureRootAuthorityInitializedLocked()
            }

            // A delayed old token, captured back when the real epoch was
            // still 0, must never be able to observe a resurrected 0
            // through this same instance either.
            #expect(throws: AssetError.self) {
                _ = try secure.readPersistedClearEpoch()
            }
        }
    }

    @Test(
        """
        Once real authority has ever been durably observed on the fast "counter exists" path, \
        a leftover witness is consumed there too -- proving cleanup is not limited to the \
        pristine-init branch alone
        """
    )
    func witnessIsConsumedOnCounterExistsFastPath() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)

            // First instance: genuinely fresh, initializes normally.
            let first = try SecureCacheDirectory(directory: root, fileManager: .default)
            try first.ensureRootAuthorityInitializedLocked()
            #expect(!witnessExists(at: root))

            // Simulate a witness left over from a pre-fix version of
            // this package (or any other external cause) resurfacing
            // alongside otherwise-perfectly-intact, already-durable
            // authority -- the "counter exists" branch, never "both
            // missing".
            try Data([0x01]).write(
                to: root.appendingPathComponent(SecureCacheDirectory.rootFreshnessWitnessFileName)
            )
            #expect(witnessExists(at: root))

            // A second, independent instance opening this same,
            // already-initialized root must sweep that leftover witness
            // the moment it observes completed authority, entirely
            // independent of its own `hasDurablyObservedRootAuthorityOnce`
            // (initially `false`).
            let second = try SecureCacheDirectory(directory: root, fileManager: .default)
            try second.ensureRootAuthorityInitializedLocked()
            #expect(second.hasDurablyObservedRootAuthorityOnce)
            #expect(!witnessExists(at: root))
            #expect(try second.readPersistedClearEpoch() == 0)
        }
    }

    @Test(
        """
        A durable failure removing the leftover witness during the pristine-init branch is \
        propagated (never silently swallowed), and the root self-heals on a subsequent retry \
        without ever re-writing the already-committed epoch/marker
        """
    )
    func witnessRemovalFailureDuringPristineInitPropagatesAndSelfHeals() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            let secure = try SecureCacheDirectory(directory: root, fileManager: .default)
            secure.installFaultInjection(
                failRemoveSuffixes: [SecureCacheDirectory.rootFreshnessWitnessFileName]
            )

            #expect(throws: AssetError.self) {
                try secure.ensureRootAuthorityInitializedLocked()
            }
            // The epoch and marker writes precede the witness-removal
            // step and must have already committed durably despite the
            // injected failure immediately afterward.
            #expect(try secure.readPersistedClearEpoch() == 0)
            #expect(
                try secure.read(name: SecureCacheDirectory.rootInitMarkerFileName, maxBytes: 1)
                    != nil
            )
            // The latch must not be set on a call that ultimately threw.
            #expect(!secure.hasDurablyObservedRootAuthorityOnce)

            // Clearing the fault and retrying must converge cleanly: the
            // "counter exists" branch now runs, sweeps the still-present
            // witness, and sets the latch -- without ever disturbing the
            // already-committed epoch value.
            secure.installFaultInjection()
            try secure.ensureRootAuthorityInitializedLocked()
            #expect(try secure.readPersistedClearEpoch() == 0)
            #expect(!witnessExists(at: root))
            #expect(secure.hasDurablyObservedRootAuthorityOnce)
        }
    }

    @Test(
        """
        A durable failure removing a leftover witness on the "counter exists" fast path is \
        propagated, and a subsequent retry converges without corrupting the already-durable \
        epoch
        """
    )
    func witnessRemovalFailureOnCounterExistsPathPropagatesAndSelfHeals() throws {
        try withScratchDirectory { base in
            let root = base.appendingPathComponent("cache", isDirectory: true)
            let first = try SecureCacheDirectory(directory: root, fileManager: .default)
            try first.ensureRootAuthorityInitializedLocked()
            _ = try first.bumpClearEpoch()

            // Reintroduce a leftover witness alongside otherwise-intact
            // authority.
            try Data([0x01]).write(
                to: root.appendingPathComponent(SecureCacheDirectory.rootFreshnessWitnessFileName)
            )

            // A second, independent, freshly-constructed instance (its
            // own latch starts `false`) opens this same root and hits
            // the "counter exists" fast path -- proving the propagated
            // failure is independent of any particular instance's own
            // latch state.
            let second = try SecureCacheDirectory(directory: root, fileManager: .default)
            second.installFaultInjection(
                failRemoveSuffixes: [SecureCacheDirectory.rootFreshnessWitnessFileName]
            )
            #expect(throws: AssetError.self) {
                try second.ensureRootAuthorityInitializedLocked()
            }
            // The real, already-bumped epoch must never be disturbed by
            // a failure that occurs purely in witness cleanup.
            #expect(try second.readPersistedClearEpoch() == 1)
            #expect(!second.hasDurablyObservedRootAuthorityOnce)

            second.installFaultInjection()
            try second.ensureRootAuthorityInitializedLocked()
            #expect(try second.readPersistedClearEpoch() == 1)
            #expect(!witnessExists(at: root))
            #expect(second.hasDurablyObservedRootAuthorityOnce)
        }
    }

    @Test(
        """
        Two independent instances racing to initialize a genuinely fresh root under the shared \
        cross-process lock converge on exactly one committed epoch-0 authority, with the \
        witness ending up durably consumed regardless of which instance's transaction actually \
        performed the pristine-init commit
        """
    )
    func concurrentInitializersOnFreshRootConvergeWithoutCorruption() async throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("RootFreshnessWitnessOneShotScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("cache", isDirectory: true)

        let first = try SecureCacheDirectory(directory: root, fileManager: .default)
        let second = try SecureCacheDirectory(directory: root, fileManager: .default)

        async let firstResult: Void = first.withExclusiveLock {
            try first.ensureRootAuthorityInitializedLocked()
        }
        async let secondResult: Void = second.withExclusiveLock {
            try second.ensureRootAuthorityInitializedLocked()
        }
        _ = try await (firstResult, secondResult)

        #expect(try first.readPersistedClearEpoch() == 0)
        #expect(
            try first.read(name: SecureCacheDirectory.rootInitMarkerFileName, maxBytes: 1) != nil
        )
        #expect(!witnessExists(at: root))
    }
}
