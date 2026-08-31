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
    /// Acquires the per-key decision lock for `key`, suspending only if
    /// another caller currently holds it. See this file's type-level doc
    /// comment for what this lock actually protects and why.
    func acquireIssuanceDecisionLock(for key: AssetCacheKey) async {
        guard issuanceDecisionLocked.contains(key) else {
            issuanceDecisionLocked.insert(key)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            issuanceDecisionWaiters[key, default: []].append(continuation)
        }
    }

    /// Releases the per-key decision lock for `key`: if another caller is
    /// already queued for it, hands the lock straight to the
    /// longest-waiting one (the lock stays logically held throughout that
    /// handoff — this key is never briefly "unlocked" in between, which
    /// could otherwise let a third, newly-arriving caller jump the queue
    /// ahead of an already-waiting one). Otherwise fully releases it.
    func releaseIssuanceDecisionLock(for key: AssetCacheKey) {
        guard var waiters = issuanceDecisionWaiters[key], !waiters.isEmpty else {
            issuanceDecisionLocked.remove(key)
            issuanceDecisionWaiters[key] = nil
            return
        }
        let next = waiters.removeFirst()
        issuanceDecisionWaiters[key] = waiters.isEmpty ? nil : waiters
        next.resume()
    }
}
