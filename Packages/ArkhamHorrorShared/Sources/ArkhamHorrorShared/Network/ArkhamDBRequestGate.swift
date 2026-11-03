import Foundation

/// Admits one account-linked ArkhamDB request at a time across the app. The server
/// spaces ArkhamDB admissions per user, so overlapping client requests only waste
/// that budget and can surface avoidable throttling errors.
///
/// User requests wait in FIFO order and are never dropped unless their own task is
/// cancelled. Background requests never wait: they are refused while a request is in
/// flight or a user request is waiting, so a background poll always yields.
///
/// Waits can be long: during a refresh-and-sync a user action can queue behind one
/// in-flight deck sync plus up to two queued ones, each with a 10 s idle request
/// timeout, so roughly 30 s or more.
actor ArkhamDBRequestGate {
    enum Priority: Sendable {
        case user
        case background
    }

    /// A background request found the gate in use or a user request waiting; nothing
    /// was sent.
    struct Busy: Error, Equatable {}

    private var isHeld = false
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var nextWaiterID = 0

    /// No request is in flight and none is waiting.
    var isIdle: Bool {
        !isHeld && waiters.isEmpty
    }

    var waitingCount: Int {
        waiters.count
    }

    /// Takes the permit. Every successful return must be balanced by `release()`.
    /// Throws `Busy` (background only) or `CancellationError`; neither holds the permit.
    func acquire(_ priority: Priority) async throws {
        switch priority {
        case .background:
            guard !isHeld, waiters.isEmpty else { throw Busy() }
            isHeld = true
        case .user:
            try Task.checkCancellation()
            // `release` hands the permit straight to the next waiter, so a free permit
            // never has waiters.
            guard isHeld else {
                isHeld = true
                return
            }
            let id = nextWaiterID
            nextWaiterID += 1
            try await withTaskCancellationHandler {
                let register = { (continuation: CheckedContinuation<Void, any Error>) in
                    self.enqueue(Waiter(id: id, continuation: continuation))
                }
                try await withCheckedThrowingContinuation(register)
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
    }

    /// Returns the permit, handing it directly to the oldest waiting user request.
    func release() {
        guard isHeld else {
            assertionFailure("ArkhamDBRequestGate released without being held")
            return
        }
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// A task cancelled before it was listed is never listed, so it cannot be missed by
    /// its cancellation handler.
    private func enqueue(_ waiter: Waiter) {
        if Task.isCancelled {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            waiters.append(waiter)
        }
    }

    /// Removes a cancelled waiter without sending anything. A waiter that already
    /// received the permit is no longer listed and keeps it until it releases.
    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
