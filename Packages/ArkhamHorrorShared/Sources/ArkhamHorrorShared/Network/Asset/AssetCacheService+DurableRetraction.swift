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
    /// **Throws instead of silently swallowing a genuine failure.** A
    /// prior revision caught every error here, recorded it into
    /// ``lastDiskPersistenceFailure``/``tombstonedKeys``, and always
    /// returned `Void` — every caller then unconditionally proceeded to
    /// resume its own waiter with plain cancellation/staleness
    /// regardless of whether this phase's durable `.retiring` commit
    /// actually landed. That let a caller observe "cancelled, nothing
    /// retained" even when this exact commit genuinely failed (a lock/
    /// write/`fsync`/rename failure) and durable disk state may still
    /// say `.content` — precisely the gap a later review round closed by
    /// requiring this to propagate a typed failure instead. Every
    /// caller of this method now must react to a thrown error by
    /// reporting a typed, non-cancellation/non-staleness outcome (see
    /// ``AssetError/retractionNotDurable(_:)`` and
    /// ``WaiterFinalOutcome/retractionNotDurable(_:)``) — never folding
    /// it into an ordinary cancellation/staleness result. The
    /// diagnostic bookkeeping (``lastDiskPersistenceFailure``/
    /// ``tombstonedKeys``) is still recorded before rethrowing, exactly
    /// as before, purely as a best-effort in-process signal to skip a
    /// disk read this actor already expects to be pointless — never
    /// itself a correctness requirement, since every disk hit for any
    /// key must independently pass a fresh online conditional
    /// revalidation before ever being trusted (see ``AssetDiskCache``'s
    /// own doc comment).
    ///
    /// **Cancellation-shielded: this exact commit runs to completion
    /// regardless of whether the *calling* waiter's own task is already
    /// (or becomes) cancelled.** Every caller of this method reaches it
    /// from a context that may itself be cancelled — a coalesced
    /// waiter's own task observing cancellation, or a zero-waiter
    /// cancellation's cleanup — and
    /// ``AssetDiskCache/beginRetraction(_:token:)``'s own disk-lock
    /// acquisition
    /// (`SecureCacheDirectoryLockCoordinator`) is itself
    /// cancellation-aware: a caller cancelled while merely *queued* for
    /// that in-process lock throws plain `CancellationError` having
    /// never even attempted the durable commit, which — left unshielded
    /// — would let this exact caller's own cancellation state (nothing
    /// to do with any genuine disk failure) abort the one operation
    /// that must complete before cancellation can safely be observed.
    /// Running the actual disk call from inside a fresh, unstructured
    /// `Task` closes this: unlike a structured child task (a task-group
    /// child, or `async let`), an unstructured `Task { ... }` does
    /// *not* inherit its creating context's cancellation state, so this
    /// commit always runs as if freshly, uncancellably started,
    /// regardless of what happens to the caller's own task concurrently.
    /// Awaiting `.result` here still keeps this call synchronous from
    /// its own caller's point of view — this method does not return
    /// until the shielded commit itself has concluded, one way or the
    /// other.
    func beginDurableRetractionIfApplied(_ key: AssetCacheKey, token: CacheToken) async throws {
        let outcome = await Task {
            try await diskCache.beginRetraction(key, token: token)
        }.result
        switch outcome {
        case .success:
            return
        case let .failure(error):
            let assetError = (error as? AssetError)
                ?? .cachePersistenceFailed(String(describing: error))
            tombstonedKeys.insert(key)
            lastDiskPersistenceFailure = assetError
            throw assetError
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
