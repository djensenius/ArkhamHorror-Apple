import Darwin
import Foundation

/// Serializes every in-process caller contending for one
/// ``SecureCacheDirectory`` instance's cross-process `flock` lock through
/// a single, bounded, FIFO queue, so that -- regardless of how many
/// concurrent in-process waiters exist -- **at most one** underlying lock
/// file descriptor and **at most one** OS-thread poller is ever active at
/// a time for that instance.
///
/// Before this type, every call to
/// ``SecureCacheDirectory/acquireExclusiveLock()`` independently opened
/// its own lock-file descriptor and dispatched its own dedicated
/// `flock(LOCK_NB)` poll-loop worker onto a shared GCD global queue: under
/// sustained in-process contention (many concurrent callers -- for
/// example many scenes/screens simultaneously touching the same disk
/// cache) this grew both open file descriptors and GCD global-queue
/// worker threads linearly with the number of concurrently *queued*
/// waiters, not merely genuinely concurrent lock holders, which a review
/// flagged as effectively unbounded resource growth under contention.
/// This type instead opens the lock file descriptor once (reused for this
/// instance's entire lifetime) and lets only the single, currently "at
/// the head of the line" in-process waiter actually poll it; every other
/// in-process waiter is suspended on an ordinary Swift continuation --
/// consuming no OS thread, no additional file descriptor, and no polling
/// of any kind -- until its turn.
///
/// A plain class synchronized by its own `os_unfair_lock` (rather than a
/// Swift actor) deliberately: an actor's own reentrancy would let a
/// second call to an `async` acquire method begin executing while a
/// first call is still suspended mid-poll (any `await` inside an actor
/// method is a reentrancy point), letting two in-process callers both
/// reach the real `flock` call concurrently through the very same shared,
/// already-open descriptor -- which would not contend at all (the same
/// open file description already holding its own lock re-locks
/// trivially), silently defeating mutual exclusion between them. Manual
/// `os_unfair_lock`-guarded state has no such reentrancy hazard: only the
/// exact code between a lock/unlock pair ever runs "atomically", and the
/// FIFO hand-off below deliberately keeps every actual state mutation
/// synchronous and lock-guarded, with the only unguarded window being the
/// real, bounded `flock` poll performed by whichever single waiter
/// currently holds local ownership. This type's raw lock file descriptor
/// must also be closable synchronously from ``SecureCacheDirectory``'s
/// own `deinit` (which cannot `await` an actor method at all).
final class SecureCacheDirectoryLockCoordinator: @unchecked Sendable {
    /// The maximum number of in-process callers allowed to be queued,
    /// waiting for their turn to even attempt the real `flock`, at once.
    /// A generous bound given this cache's own realistic call volume, but
    /// still a genuine, enforced ceiling: pathological/adversarial
    /// contention fails closed with a typed error rather than growing
    /// this queue -- and therefore this process's own outstanding-
    /// continuation memory -- without bound.
    static let maxQueuedWaiters = 256

    /// A single queued in-process waiter: its continuation, plus a
    /// monotonically increasing `id` so a cancellation handler firing on
    /// an arbitrary thread can find and remove *this exact* entry from
    /// ``waiters`` (continuations themselves are not otherwise
    /// identifiable or comparable) without racing a concurrent normal
    /// dequeue of the very same entry.
    private struct QueuedWaiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var unfairLock = os_unfair_lock()
    private var lockFD: Int32 = -1
    private var isLocallyHeld = false
    private var waiters: [QueuedWaiter] = []
    private var nextWaiterID = 0

    /// Test-only observability seam: invoked synchronously, exactly once
    /// per call to ``waitForLocalTurn()``, immediately after this
    /// caller's position in the FIFO ordering has been durably
    /// established (either granted immediately or appended to
    /// ``waiters``) -- never before, and never based on timing. Nil in
    /// production (zero behavioral effect); tests use it to serialize
    /// their own submission order deterministically, since Swift's
    /// `Task.sleep`-based staggering only guarantees a *minimum* delay,
    /// not an upper bound, and so cannot by itself prove real call order
    /// under scheduler contention.
    var onWaiterPositionEstablished: (() -> Void)?

    /// A dedicated GCD queue used only to host the blocking `flock(2)`
    /// acquire *poll* below, kept entirely off Swift concurrency's
    /// fixed-size cooperative thread pool -- see
    /// ``SecureCacheDirectory``'s predecessor doc comment for why a
    /// blocking wait can never run directly on that pool. Unlike the
    /// predecessor design, at most one poll (from whichever single
    /// in-process caller currently holds local ownership) is ever
    /// dispatched onto this queue at a time for a given coordinator
    /// instance, regardless of how many in-process callers are queued
    /// behind it.
    private static let lockAcquireQueue = DispatchQueue.global(qos: .utility)

    /// How long each failed non-blocking acquire attempt sleeps before
    /// retrying — short enough that a waiting caller's own cancellation is
    /// observed promptly, long enough that busy-waiting many concurrent
    /// waiters does not meaningfully burn CPU while a lock is held for its
    /// normal, brief critical-section duration.
    private static let pollIntervalMicroseconds: UInt32 = 2000

    deinit {
        if lockFD >= 0 {
            close(lockFD)
        }
    }

    /// Acquires this coordinator's shared lock file descriptor -- opening
    /// and verifying it via `verify` on first use only -- after waiting
    /// for this in-process caller's own FIFO turn, then performing the
    /// real, cancellation-aware `flock(LOCK_EX)` poll. Returns the held,
    /// verified descriptor; the caller must release via ``release(expectedFD:)``
    /// exactly once, typically from a `defer` immediately after this
    /// call.
    func acquire(
        rootFD: Int32,
        verify: (Int32) throws -> Void
    ) async throws -> Int32 {
        try await waitForLocalTurn()
        do {
            let descriptor = try openLockFDIfNeeded(rootFD: rootFD, verify: verify)
            try await Self.pollUntilAcquiredOrCancelled(descriptor)
            // The poll above can only return successfully with the lock
            // genuinely held (a cancellation mid-poll instead throws
            // `CancellationError`, never resuming with a silently-still-
            // held lock) — but a cancellation delivered in the narrow
            // window *after* that resume and *before* this line runs
            // would otherwise let a cancelled caller still walk away with
            // a held lock and proceed to mutate. Checking here, before
            // ever returning the descriptor to the caller, closes that
            // window: on cancellation the lock is released right here
            // rather than by some caller that may never reach its own
            // `defer`.
            try Task.checkCancellation()
            return descriptor
        } catch {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
            }
            releaseLocalTurn()
            throw error
        }
    }

    /// Releases the real `flock` hold and hands local ownership to the
    /// next queued in-process waiter, if any (never closing or
    /// re-opening the shared descriptor). `expectedFD` is only sanity-
    /// checked (a mismatch here would indicate a caller holding a stale
    /// descriptor from some earlier, already-closed coordinator state)
    /// rather than acted on, since this coordinator's own single
    /// descriptor is already authoritative.
    func release(expectedFD: Int32) {
        os_unfair_lock_lock(&unfairLock)
        let currentFD = lockFD
        os_unfair_lock_unlock(&unfairLock)
        guard currentFD >= 0, currentFD == expectedFD || expectedFD < 0 else { return }
        flock(currentFD, LOCK_UN)
        releaseLocalTurn()
    }

    private func openLockFDIfNeeded(
        rootFD: Int32,
        verify: (Int32) throws -> Void
    ) throws -> Int32 {
        os_unfair_lock_lock(&unfairLock)
        let existing = lockFD
        os_unfair_lock_unlock(&unfairLock)
        if existing >= 0 {
            return existing
        }
        let descriptor = openat(
            rootFD, SecureCacheDirectory.lockFileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard descriptor >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open cache lock file (errno \(errno))"
            )
        }
        do {
            try verify(descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        os_unfair_lock_lock(&unfairLock)
        lockFD = descriptor
        os_unfair_lock_unlock(&unfairLock)
        return descriptor
    }

    /// Suspends until this in-process caller becomes the sole holder of
    /// "local ownership" -- either immediately (no other in-process
    /// caller currently holds it) or after every earlier-queued waiter
    /// has released, in strict FIFO order. Cancellation-aware: a
    /// cancelled caller still sitting in ``waiters`` is found -- by its
    /// own unique `id`, allocated *before* this waiter ever suspends, so
    /// a concurrent cancellation can never be confused with, and mistake
    /// resuming, some other still-legitimately-waiting caller -- and
    /// resumed with `CancellationError` immediately, rather than only
    /// discovering its own cancellation once it eventually reaches the
    /// front of the queue.
    private func waitForLocalTurn() async throws {
        let id = allocateWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: LockAcquireContinuation) in
                os_unfair_lock_lock(&unfairLock)
                if !isLocallyHeld {
                    isLocallyHeld = true
                    os_unfair_lock_unlock(&unfairLock)
                    continuation.resume()
                    onWaiterPositionEstablished?()
                    return
                }
                guard waiters.count < Self.maxQueuedWaiters else {
                    os_unfair_lock_unlock(&unfairLock)
                    continuation.resume(
                        throwing: AssetError.cachePersistenceFailed(
                            "Too many concurrent cache-lock waiters"
                        )
                    )
                    onWaiterPositionEstablished?()
                    return
                }
                waiters.append(QueuedWaiter(id: id, continuation: continuation))
                os_unfair_lock_unlock(&unfairLock)
                onWaiterPositionEstablished?()
            }
        } onCancel: { [weak self] in
            self?.cancelQueuedWaiter(id: id)
        }
    }

    private func allocateWaiterID() -> Int {
        os_unfair_lock_lock(&unfairLock)
        let id = nextWaiterID
        nextWaiterID += 1
        os_unfair_lock_unlock(&unfairLock)
        return id
    }

    /// Finds and removes the exact queued waiter matching `id` (if it is
    /// still queued -- it may already have been normally dequeued by a
    /// concurrent ``releaseLocalTurn()`` racing this same cancellation, or
    /// may already hold "local ownership" outright, in either of which
    /// cases there is nothing left to do here since nothing with this
    /// `id` remains in ``waiters``), and resumes *that* waiter with
    /// `CancellationError`. Never removes any other, still-legitimately-
    /// waiting entry.
    private func cancelQueuedWaiter(id: Int) {
        os_unfair_lock_lock(&unfairLock)
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            os_unfair_lock_unlock(&unfairLock)
            return
        }
        let cancelled = waiters.remove(at: index)
        os_unfair_lock_unlock(&unfairLock)
        cancelled.continuation.resume(throwing: CancellationError())
    }

    private func releaseLocalTurn() {
        os_unfair_lock_lock(&unfairLock)
        if waiters.isEmpty {
            isLocallyHeld = false
            os_unfair_lock_unlock(&unfairLock)
            return
        }
        let next = waiters.removeFirst()
        os_unfair_lock_unlock(&unfairLock)
        next.continuation.resume()
    }

    /// A small, lock-guarded flag shared between a
    /// ``withTaskCancellationHandler(operation:onCancel:)`` cancellation
    /// callback (which can fire on an arbitrary thread, at any time,
    /// including concurrently with the poll loop below reading it) and
    /// ``pollUntilAcquiredOrCancelled(_:)``'s own poll loop — never a
    /// Swift actor, since the poll loop itself must stay entirely
    /// synchronous (non-`async`) to keep spinning at a tight, predictable
    /// interval on its dedicated GCD queue.
    private final class CancellationFlag: @unchecked Sendable {
        private var unfairLock = os_unfair_lock()
        private var isCancelled = false

        func markCancelled() {
            os_unfair_lock_lock(&unfairLock)
            isCancelled = true
            os_unfair_lock_unlock(&unfairLock)
        }

        func checkCancelled() -> Bool {
            os_unfair_lock_lock(&unfairLock)
            defer { os_unfair_lock_unlock(&unfairLock) }
            return isCancelled
        }
    }

    /// A shorthand for the specific continuation type this poll resumes,
    /// existing purely so that closure's parameter type annotation
    /// (needed to work around a Swift compiler crash — "failed to produce
    /// diagnostic for expression" — reproducibly hit when the
    /// fully-general `CheckedContinuation<Void, Error>` spelling is
    /// inferred implicitly here) fits on the same line as the closure's
    /// opening brace within this package's line-length limit.
    private typealias LockAcquireContinuation = CheckedContinuation<Void, Error>

    /// Performs the `flock(lockFD, LOCK_EX | LOCK_NB)` acquire as a
    /// cancellation-aware, non-blocking poll loop on ``lockAcquireQueue``
    /// rather than the calling task's own executor, and rather than a
    /// single indefinite blocking `LOCK_EX` wait, exactly once per call --
    /// only ever invoked while this coordinator's own FIFO already
    /// guarantees this is the sole in-process caller attempting it.
    ///
    /// A plain blocking `flock(LOCK_EX)` wait cannot observe Swift `Task`
    /// cancellation at all: a caller whose surrounding `Task` was
    /// cancelled while still waiting for a lock held by another (possibly
    /// very slow, or even hung) holder would leak its
    /// ``lockAcquireQueue`` worker thread for as long as that other
    /// holder kept the lock — potentially forever, unbounded by anything
    /// this caller itself does. Polling with `LOCK_NB` at
    /// ``pollIntervalMicroseconds`` and checking a shared
    /// ``CancellationFlag`` (set by `withTaskCancellationHandler`'s
    /// `onCancel` callback, which can fire from any thread at any time)
    /// every iteration bounds that leak to at most one poll interval, and
    /// lets a cancelled waiter's continuation resume with
    /// `CancellationError` instead of silently, and incorrectly, resuming
    /// as if the lock had been genuinely acquired.
    private static func pollUntilAcquiredOrCancelled(_ lockFD: Int32) async throws {
        let flag = CancellationFlag()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: LockAcquireContinuation) in
                lockAcquireQueue.async {
                    while true {
                        if flag.checkCancelled() {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                            continuation.resume()
                            return
                        }
                        if errno == EINTR {
                            continue
                        }
                        if errno == EWOULDBLOCK {
                            usleep(pollIntervalMicroseconds)
                            continue
                        }
                        continuation.resume(
                            throwing: AssetError.cachePersistenceFailed(
                                "flock failed to acquire (errno \(errno))"
                            )
                        )
                        return
                    }
                }
            }
        }, onCancel: {
            flag.markCancelled()
        })
    }
}
