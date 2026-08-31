import Foundation

/// This actor's two-phase durable retraction of an already-applied
/// mutation — split out of `AssetCacheService+Epoch.swift` purely to
/// keep that file within this package's `file_length` convention. See
/// that file's own type-level doc comment for the full authority model
/// these two phases operate under.
extension AssetCacheService {
    /// Phase 1 of this actor's two-phase retraction of an
    /// already-applied mutation — the durable, disk-side `.retiring`
    /// commit alone (``AssetDiskCache/beginRetraction(_:token:)``),
    /// never the physical deletion or final `.tombstone` commit
    /// (``completeDurableRetractionIfApplied(_:token:)`` below performs
    /// those). Used by every one of this subsystem's retraction points —
    /// a cancelled last waiter
    /// (`AssetCacheService+Coalescing.swift`'s
    /// ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)``,
    /// `AssetCacheService+RevalidationCoalescing.swift`'s
    /// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``)
    /// and a straggling coalesced waiter that finalizes only after its
    /// shared operation already completed without any waiter taking
    /// delivery (`AssetCacheService+WaiterAcknowledgement.swift`'s
    /// `retractUndeliveredMutation(_:token:)`) — every one of which must
    /// `await` this exact call to completion *before* letting its own
    /// waiter observe cancellation/staleness: see
    /// ``AssetDiskCache/beginRetraction(_:token:)``'s own doc comment
    /// for the full "durable state must never still say `.content`
    /// by the time anyone is told nothing was retained" reasoning this
    /// closes, and this file's own type-level doc comment for why a
    /// prior revision's detached, unawaited retraction task left that
    /// window open.
    ///
    /// Deliberately never throws: a genuine disk-side failure here means
    /// this phase's own durable transition could not be confirmed, which
    /// this actor can no longer prove either way — mirroring
    /// ``invalidate(_:token:)``'s own identical reaction to an
    /// unconfirmed disk mutation, this records the failure
    /// (``lastDiskPersistenceFailure``) and marks `key` tombstoned
    /// (``tombstonedKeys``) — a purely in-process, best-effort signal to
    /// skip a disk read this actor already expects to be pointless, never
    /// a correctness requirement, since every disk hit for any key must
    /// independently pass a fresh online conditional revalidation before
    /// ever being trusted (see ``AssetDiskCache``'s own doc comment) —
    /// but this failure must never be silently discarded as if the
    /// retraction had definitely succeeded, the exact defect a prior
    /// review flagged in this method's own disk-layer counterpart. Every
    /// caller still resumes its own waiter with plain cancellation/
    /// staleness regardless of whether this phase durably succeeded:
    /// once this actor can no longer trust `key`'s own disk state either
    /// way, ``tombstonedKeys`` already fails this process's own future
    /// reads of it closed, which is the strongest guarantee available
    /// once a genuine I/O failure — as opposed to a merely undelivered
    /// waiter — is what is actually being reported.
    func beginDurableRetractionIfApplied(_ key: AssetCacheKey, token: CacheToken) async {
        do {
            try await diskCache.beginRetraction(key, token: token)
        } catch let error as AssetError {
            tombstonedKeys.insert(key)
            lastDiskPersistenceFailure = error
        } catch {
            tombstonedKeys.insert(key)
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }

    /// Phase 2: the memory-side removal
    /// (``AssetMemoryCache/removeIfApplied(_:token:)``) and the
    /// disk-side physical deletion + final `.tombstone` commit
    /// (``AssetDiskCache/completeRetraction(_:token:)``) — safe to run
    /// asynchronously/detached from whichever caller's own
    /// ``beginDurableRetractionIfApplied(_:token:)`` call preceded it
    /// (every production call site does exactly this: fires this method
    /// from its own detached, strongly-`self`-capturing `Task` only
    /// *after* phase 1 has already been awaited to completion), since by
    /// the time this runs `key` is already durably unreadable regardless
    /// — see phase 1's own doc comment. Identical failure handling to
    /// phase 1: a genuine disk failure is recorded, never silently
    /// swallowed.
    func completeDurableRetractionIfApplied(_ key: AssetCacheKey, token: CacheToken) async {
        await memoryCache.removeIfApplied(key, token: token)
        do {
            try await diskCache.completeRetraction(key, token: token)
        } catch let error as AssetError {
            tombstonedKeys.insert(key)
            lastDiskPersistenceFailure = error
        } catch {
            tombstonedKeys.insert(key)
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }
}
