import Foundation

/// The two-phase retraction primitives ``AssetDiskCache/removeIfApplied(_:token:)``
/// composes — split out of `AssetDiskCache+TokenCAS.swift` purely to
/// keep that file within this package's `file_length` convention.
extension AssetDiskCache {
    /// Phase 1 of the two-phase retraction ``removeIfApplied(_:token:)``
    /// composes: durably commits `.retiring(token's ticket)` -- and
    /// **only** that transition, never the physical deletion or the
    /// final `.tombstone` commit ``completeRetraction(_:token:)`` below
    /// performs -- if `token` is still exactly the currently-applied
    /// disposition for `key`.
    ///
    /// **Exists as its own, separately-awaitable step specifically so
    /// `AssetCacheService`'s own actor-level retraction callers
    /// (`AssetCacheService+Coalescing.swift`'s
    /// ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)``,
    /// `AssetCacheService+RevalidationCoalescing.swift`'s
    /// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``,
    /// and `AssetCacheService+WaiterAcknowledgement.swift`'s
    /// `retractUndeliveredMutation(_:token:)`) can `await` this exact
    /// commit landing durably *before* letting any waiter -- including
    /// the one whose cancellation triggered it -- observe cancellation
    /// or staleness for an operation that may already have durably
    /// published `token`'s own content.** A prior revision folded this
    /// together with the physical deletion and final tombstone commit
    /// into one single-shot call, invoked from a detached/unawaited
    /// `Task` that those actor-level callers never waited on before
    /// resuming their own waiter — durably correct once it eventually
    /// ran, but with no guarantee it had even *started* by the time a
    /// waiter (or, worse, an entirely independent sibling process, or
    /// this same process after a crash) could already be told "cancelled,
    /// nothing retained" while the disk disposition was still durably
    /// `.content`. Splitting the durable-but-cheap `.retiring` commit
    /// out from the (best-effort, and therefore safe to defer) physical
    /// cleanup closes that window: `AssetDiskCache/get(_:)`'s own
    /// disposition cross-check already refuses to serve anything but an
    /// exactly-matching `.content` disposition (see that method's own
    /// doc comment), so the instant this phase's commit lands, `key` is
    /// unreadable to *every* reader — this process, a sibling process
    /// sharing the same directory, or this same process after a restart
    /// — regardless of whether the metadata/payload files themselves
    /// have physically been removed yet.
    ///
    /// Returns ``AssetCacheService/MutationOutcome/stale`` (never
    /// throwing) when `token` is no longer exactly the applied ticket
    /// for `key`, or when this exact ticket's own disposition is already
    /// a non-content kind — genuinely nothing to retract, not a failure
    /// — and ``AssetCacheService/MutationOutcome/applied`` once the
    /// `.retiring` transition (or the discovery that nothing needed one)
    /// has durably completed. A genuine disk I/O failure (lock
    /// acquisition, root-authority initialization, the epoch/disposition
    /// reads, or the `.retiring` commit's own write) always propagates
    /// as a typed ``AssetError`` — never silently treated as either
    /// outcome — so a caller that cannot confirm this exact durable
    /// transition landed must never assume content is safely retracted.
    @discardableResult
    func beginRetraction(
        _ key: AssetCacheKey,
        token: AssetCacheService.CacheToken
    ) async throws -> AssetCacheService.MutationOutcome {
        if let pause = testOnlyPauseBeforeAcquiringRemovalLock {
            await pause()
        }
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        guard
            let issuedTicket = token.diskWriteGeneration,
            let issuedEpoch = token.durableClearEpoch
        else {
            return .stale
        }
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        guard currentEpoch == issuedEpoch else { return .stale }
        let disposition = try currentDispositionLocked(for: key)
        guard disposition.ticket == issuedTicket else { return .stale }
        guard disposition.kind == .content else {
            // This exact ticket's own durable disposition is already a
            // deletion/retirement (a definitive 404's own `invalidate`
            // commit, a previously interrupted retraction of this very
            // ticket, or this exact phase having already run once
            // before) — see this method's own doc comment. There is no
            // live content publication left here to roll back; simply
            // report this phase as already satisfied.
            return .applied
        }
        try commitDispositionLocked(
            KeyDisposition(ticket: issuedTicket, kind: .retiring, contentHash: nil),
            for: key
        )
        return .applied
    }

    /// Phase 2 of the two-phase retraction ``removeIfApplied(_:token:)``
    /// composes: performs the actual (best-effort once this transition
    /// itself durably lands — see ``AssetDiskCache/commitRetractionLocked(for:token:destroy:)``'s
    /// own doc comment) physical deletion and commits the final
    /// `.tombstone(token's ticket)` disposition — but **only** if this
    /// exact ticket's disposition is still exactly `.retiring`
    /// (``beginRetraction(_:token:)`` already durably committed it, and
    /// nothing newer has since published over it). A silent no-op, not
    /// an error, when this exact ticket's disposition has already moved
    /// past `.retiring` — a fresh mutation for this key durably
    /// superseded it, or an earlier/concurrent call to this exact phase
    /// already finished it — since there is nothing left for *this* call
    /// to do.
    ///
    /// Safe to run detached from whichever caller's own
    /// ``beginRetraction(_:token:)`` call preceded it: by the time this
    /// runs, `key` is already durably unreadable (per
    /// ``beginRetraction(_:token:)``'s own doc comment), so nothing
    /// depends on this phase completing before any waiter's outcome is
    /// observed — only the eventual reclamation of physical disk space
    /// and the final, fully-resolved `.tombstone` disposition do.
    func completeRetraction(
        _ key: AssetCacheKey,
        token: AssetCacheService.CacheToken
    ) async throws {
        guard let issuedTicket = token.diskWriteGeneration else { return }
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let disposition = try currentDispositionLocked(for: key)
        guard disposition.kind == .retiring, disposition.ticket == issuedTicket else {
            return
        }
        let metadataWasPresent = try secureDirectory.remove(name: metadataFilename(for: key))
        try secureDirectory.fsyncRootDirectory()
        if metadataWasPresent {
            cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
        }
        try commitDispositionLocked(
            KeyDisposition(ticket: issuedTicket, kind: .tombstone, contentHash: nil),
            for: key
        )
    }
}
