import Foundation

/// One-time-per-instance wiring between ``AssetDiskCache`` and its
/// ``SecureCacheDirectory``'s durable root-authority initialization (see
/// `SecureCacheDirectory+ClearEpoch.swift`'s type-level doc comment for
/// what that initialization actually establishes and why it must be a
/// cross-process locked transaction). Split into its own file purely to
/// keep `AssetDiskCache.swift` within this package's `file_length`
/// convention, exactly like `AssetDiskCache+Recovery.swift`.
extension AssetDiskCache {
    /// Ensures this instance's shared directory has its durable root
    /// authority (the permanent root-init marker and the clear-epoch
    /// counter) initialized, at most once per `AssetDiskCache` instance —
    /// mirrors ``recoverOrphansIfNeeded()``'s identical one-time-per-
    /// instance pattern, and now *itself* invokes it (see below) as its
    /// own very first step, as the very first step of every locked entry
    /// point in this actor (``set(_:payload:metadata:token:)``,
    /// ``touch(_:metadata:token:)``, ``remove(_:token:)``,
    /// ``removeAll()``, ``beginIssuance(for:)``), before any of them ever
    /// reads or writes the durable clear-epoch counter.
    ///
    /// **Must only ever be called while the caller already holds this
    /// instance's own ``SecureCacheDirectory/acquireExclusiveLock()``** —
    /// exactly like ``SecureCacheDirectory/ensureRootAuthorityInitializedLocked()``
    /// itself requires, since the whole point of moving this out of
    /// `SecureCacheDirectory.init(directory:fileManager:)` (which cannot
    /// itself acquire that `async` lock) is to make the entire "check
    /// marker/epoch, then create both if genuinely missing" sequence run
    /// as one atomic, cross-process-mutually-exclusive transaction.
    ///
    /// Only marks itself done once the underlying call actually succeeds:
    /// a failure here (this root was previously initialized and its
    /// epoch was since lost/corrupted, or the durable write itself
    /// failed) must not be permanently cached as "already handled" —
    /// every subsequent call must keep re-attempting and re-surfacing
    /// that same fail-closed failure, never silently proceeding as if
    /// authority were confirmed.
    ///
    /// Deliberately invokes ``recoverOrphansIfNeeded()`` itself, *before*
    /// delegating to
    /// ``SecureCacheDirectory/ensureRootAuthorityInitializedLocked(isSurvivingEntryAcceptable:)``,
    /// rather than leaving every call site to sequence the two
    /// separately (a prior revision's own convention) — folding both
    /// steps into one call guarantees every locked entry point gets them
    /// in this exact order, rather than relying on each call site to
    /// never regress it.
    ///
    /// **Rejects every survivor unconditionally, with exactly one narrow,
    /// explicitly-justified exception: the fixed-name whole-cache
    /// disk-writes-disabled marker (``AssetDiskCache/diskWritesDisabledMarkerName``).**
    /// A prior revision instead supplied a closure that tolerated *any*
    /// survivor as long as ``recoverOrphansIfNeeded()`` had not classified
    /// at least one surviving name as a genuine, currently-valid,
    /// referenced cache entry — but that criterion only ever looked at
    /// whether a `.meta.json`/`.bin` *pair* was still fully intact; it
    /// said nothing about, and so silently waved through, every other
    /// kind of survivor recovery cannot prove is harmless first-init
    /// debris: a leftover per-key `.gen`/`.applied` write-generation
    /// ticket file (definitive proof this exact key was previously
    /// issued/mutated, regardless of whether its content ever fully
    /// published), an orphaned `.tmp`/`.bin` that
    /// ``sweepOrphanFiles(names:referencedPayloadFilenames:)`` attempted
    /// but failed to remove, a corrupt/undecodable `.meta.json` sidecar
    /// (removed by the classification loop above, but only best-effort —
    /// a failed removal there survives this pass too), or a non-regular
    /// entry (directory/FIFO/device/symlink) at any cache-owned name.
    /// Every one of those is either definite evidence of prior real use
    /// or a genuine classification/removal uncertainty this transaction
    /// cannot safely resolve — and either one, left unaccounted for,
    /// could let a root that was never actually pristine still be
    /// initialized to clear-epoch `0`, silently resurrecting whatever
    /// authority a real prior clear (or a still-uncertain survivor's own
    /// true history) was supposed to have revoked or still be
    /// protecting. Rejecting every one of *those* unconditionally is the
    /// only criterion provably safe.
    ///
    /// The disk-writes-disabled marker is categorically different: it is
    /// written *only* by ``AssetDiskCache/markDiskWritesDisabledLocked()``,
    /// itself reachable only from a locked entry point already past this
    /// exact check (``recoverOrphansIfNeeded()``'s own unenumerable-
    /// listing branch, or ``AssetDiskCache/evictIfNeeded()``'s identical
    /// one) — never as any byproduct of genuine cache content, a per-key
    /// mutation, or a prior clear. Its presence or absence carries zero
    /// information about whether this root was ever previously cleared;
    /// it means only "a *write budget* could not be proven as of some
    /// earlier attempt," a concern ``AssetDiskCache/requireDiskWritesEnabledLocked()``
    /// (called immediately after this method succeeds, from the same
    /// `setLocked` critical section) already independently, durably
    /// re-verifies and clears-or-keeps on its own, via
    /// ``AssetDiskCache/evictIfNeeded()`` — every write this method itself
    /// permits still passes through that unconditionally. Rejecting this
    /// exact marker here instead would durably deadlock root-authority
    /// initialization forever the moment even one *transient* listing
    /// failure (a single unlucky `recoverOrphansIfNeeded()`/
    /// `evictIfNeeded()` call, on a root that has otherwise never been
    /// written to at all) ever wrote it once: initialization would keep
    /// finding this now-permanent survivor and refusing to proceed, even
    /// once the very next listing attempt proves the directory is
    /// otherwise genuinely empty — the marker's own clearing path can
    /// never even run, since it is gated behind this method succeeding
    /// first.
    func ensureRootAuthorityInitializedLocked() throws {
        guard !didEnsureRootAuthorityInitialized else { return }
        recoverOrphansIfNeeded(forceRetry: true)
        try secureDirectory.ensureRootAuthorityInitializedLocked(
            isSurvivingEntryAcceptable: { $0 == Self.diskWritesDisabledMarkerName }
        )
        didEnsureRootAuthorityInitialized = true
    }
}
