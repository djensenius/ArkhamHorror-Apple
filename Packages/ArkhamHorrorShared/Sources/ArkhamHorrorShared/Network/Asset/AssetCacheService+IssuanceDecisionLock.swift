import Foundation

/// Serializes, per ``AssetCacheKey``, the decision of whether a fresh
/// fetch/revalidation should join already-registered in-flight work for
/// that key or begin fresh work of its own — including any durable disk
/// authority reservation
/// (``AssetCacheService/beginIssuance(for:)``/`beginRevalidationIssuance`)
/// that starting fresh work requires.
///
/// Without this, Swift's actor reentrancy lets two concurrent calls for
/// the very same key each suspend *inside their own* disk-authority
/// reservation before either resumes far enough to observe the other's
/// now-registered `inFlight`/`inFlightRevalidation` entry: both then
/// reserve distinct, genuinely-issued disk tickets, yet only one of those
/// two reservations is ever actually attached to the shared operation
/// every waiter (including the caller that "lost" the race and merely
/// joins) ends up relying on — the other is silently wasted. Under
/// `AssetDiskCache+TokenCAS.swift`'s per-key issuance-ordered authority
/// (``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)`` fences
/// any lower *issued* ticket, not merely a lower *applied* one — see that
/// file's doc comment for why), that wasted-but-still-issued ticket
/// permanently and incorrectly fences out the ticket the actually-in-use
/// shared operation holds, so it can never publish — surfacing to every
/// one of its waiters as ``AssetError/staleOperation`` despite nothing
/// about the operation itself ever having been superseded.
///
/// A simple actor-isolated FIFO mutex, keyed by ``AssetCacheKey``:
/// acquiring while unlocked locks immediately, with no suspension;
/// acquiring while already locked suspends until every earlier waiter for
/// this exact key has released. Deliberately held only around the
/// synchronous-ish join-or-create decision itself (including whatever
/// authority reservation starting fresh work requires) — never around
/// the (potentially long-running) wait for that work's eventual result —
/// so a caller that only needs to join already-registered work is never
/// blocked behind another key's unrelated decision, and this key's own
/// lock is held only as long as it takes to either observe existing work
/// or fully register fresh work (at which point any other, later caller
/// for this same key that acquires the lock will find that fresh work
/// already registered, and simply join it without reserving anything of
/// its own).
extension AssetCacheService {
    /// A single queued in-process waiter for one ``AssetCacheKey``'s
    /// decision lock: its continuation, plus a monotonically increasing
    /// `id` (``AssetCacheService/nextIssuanceDecisionWaiterID``) so a
    /// cancellation handler firing on an arbitrary executor can find and
    /// remove *this exact* entry from
    /// ``AssetCacheService/issuanceDecisionWaiters`` — never some other,
    /// still-legitimately-waiting caller's — without racing a concurrent
    /// normal hand-off of that very same entry. Mirrors
    /// ``SecureCacheDirectoryLockCoordinator/QueuedWaiter``.
    struct QueuedIssuanceDecisionWaiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Acquires the per-key decision lock for `key`, suspending only if
    /// another caller currently holds it. See this file's type-level doc
    /// comment for what this lock actually protects and why.
    ///
    /// Cancellation-aware on both the queued-wait and the immediately-
    /// granted path: a caller cancelled while still queued is found (by
    /// its own stable `id`, allocated *before* it ever suspends) and
    /// resumed with `CancellationError` immediately, rather than only
    /// discovering its own cancellation once it eventually reaches the
    /// front of the queue and is handed a lock it can no longer
    /// legitimately use. A cancellation delivered in the narrow window
    /// *after* a queued waiter's continuation is resumed (handing it the
    /// lock) but *before* this method returns to its caller — racing
    /// ``releaseIssuanceDecisionLock(for:)``'s own hand-off — is closed
    /// by the `Task.isCancelled` check just before returning below:
    /// on cancellation, the lock this caller was just granted is
    /// released right here (handing it on to the *next* queued waiter,
    /// if any) rather than silently handed back to a caller that will
    /// never use it, which would otherwise leave every later waiter for
    /// this key stuck behind a lock nobody is ever going to release.
    /// Throwing at all times means "this caller never gets to use the
    /// lock and owes no matching release" — every call site relies on
    /// exactly that invariant.
    func acquireIssuanceDecisionLock(for key: AssetCacheKey) async throws {
        guard issuanceDecisionLocked.contains(key) else {
            issuanceDecisionLocked.insert(key)
            if Task.isCancelled {
                releaseIssuanceDecisionLock(for: key)
                throw CancellationError()
            }
            return
        }
        let id = nextIssuanceDecisionWaiterID
        nextIssuanceDecisionWaiterID += 1
        try await withTaskCancellationHandler {
            typealias LockContinuation = CheckedContinuation<Void, Error>
            try await withCheckedThrowingContinuation { (continuation: LockContinuation) in
                issuanceDecisionWaiters[key, default: []].append(
                    QueuedIssuanceDecisionWaiter(id: id, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelQueuedIssuanceDecisionWaiter(key, id: id) }
        }
        if Task.isCancelled {
            releaseIssuanceDecisionLock(for: key)
            throw CancellationError()
        }
    }

    /// Finds and removes the exact queued waiter matching `id` for `key`
    /// (if it is still queued — it may already have been normally
    /// dequeued by a concurrent ``releaseIssuanceDecisionLock(for:)``
    /// racing this same cancellation, in which case there is nothing
    /// left to do here: that hand-off's own resumed waiter is caught by
    /// ``acquireIssuanceDecisionLock(for:)``'s own post-grant
    /// `Task.isCancelled` check instead), and resumes *that* waiter with
    /// `CancellationError`. Never removes or resumes any other,
    /// still-legitimately-waiting entry.
    private func cancelQueuedIssuanceDecisionWaiter(_ key: AssetCacheKey, id: Int) {
        guard var waiters = issuanceDecisionWaiters[key],
              let index = waiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let cancelled = waiters.remove(at: index)
        issuanceDecisionWaiters[key] = waiters.isEmpty ? nil : waiters
        cancelled.continuation.resume(throwing: CancellationError())
    }

    /// Releases the per-key decision lock for `key`: if another caller is
    /// already queued for it, hands the lock straight to the
    /// longest-waiting one (the lock stays logically held throughout that
    /// handoff — this key is never briefly "unlocked" in between, which
    /// could otherwise let a third, newly-arriving caller jump the queue
    /// ahead of an already-waiting one). Otherwise fully releases it.
    ///
    /// The waiter handed the lock here may go on to discover, in
    /// ``acquireIssuanceDecisionLock(for:)``'s own post-grant check, that
    /// it was cancelled at (or immediately before) this exact hand-off —
    /// that check, not this method, is what prevents a cancelled waiter
    /// from actually using a lock it is resumed with here; this method
    /// itself only ever hands off to the single longest-waiting *still-
    /// queued* entry (any waiter already cancelled away by
    /// ``cancelQueuedIssuanceDecisionWaiter(_:id:)`` is no longer present
    /// in ``AssetCacheService/issuanceDecisionWaiters`` at all by the time
    /// this runs).
    func releaseIssuanceDecisionLock(for key: AssetCacheKey) {
        guard var waiters = issuanceDecisionWaiters[key], !waiters.isEmpty else {
            issuanceDecisionLocked.remove(key)
            issuanceDecisionWaiters[key] = nil
            return
        }
        let next = waiters.removeFirst()
        issuanceDecisionWaiters[key] = waiters.isEmpty ? nil : waiters
        next.continuation.resume()
    }
}
