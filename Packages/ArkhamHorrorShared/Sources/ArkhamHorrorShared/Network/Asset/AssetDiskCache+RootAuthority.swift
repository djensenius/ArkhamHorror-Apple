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
    /// separately (a prior revision's own convention): the root-authority
    /// decision for a directory with no epoch and no marker needs to know
    /// whether recovery found any *genuine* surviving entry
    /// (``foundGenuineExistingEntryDuringRecovery``), and that can only be
    /// known accurately once recovery has actually had a chance to
    /// reclaim whatever reclaimable debris it can first — folding both
    /// steps into one call also guarantees every locked entry point gets
    /// them in this exact order, rather than relying on each call site to
    /// never regress it.
    func ensureRootAuthorityInitializedLocked() throws {
        guard !didEnsureRootAuthorityInitialized else { return }
        recoverOrphansIfNeeded()
        try secureDirectory.ensureRootAuthorityInitializedLocked(
            isSurvivingEntryAcceptable: { [foundGenuineExistingEntryDuringRecovery] _ in
                !foundGenuineExistingEntryDuringRecovery
            }
        )
        didEnsureRootAuthorityInitialized = true
    }
}
