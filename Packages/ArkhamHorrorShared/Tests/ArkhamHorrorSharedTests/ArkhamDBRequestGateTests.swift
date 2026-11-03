@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Records the order in which gate holders ran.
private actor Order {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

@Suite("ArkhamDB request gate", .timeLimit(.minutes(1)))
struct ArkhamDBRequestGateTests {
    private func waitForWaiters(_ gate: ArkhamDBRequestGate, _ count: Int) async {
        while await gate.waitingCount < count {
            await Task.yield()
        }
    }

    @Test("A free gate admits a user request at once and is idle after release")
    func freeGateAdmits() async throws {
        let gate = ArkhamDBRequestGate()
        #expect(await gate.isIdle)
        try await gate.acquire(.user)
        #expect(await !gate.isIdle)
        #expect(await gate.waitingCount == 0)
        await gate.release()
        #expect(await gate.isIdle)
    }

    @Test("User requests queue in FIFO order and receive the permit directly")
    func userFIFO() async throws {
        let gate = ArkhamDBRequestGate()
        let order = Order()
        try await gate.acquire(.user)
        var tasks: [Task<Void, any Error>] = []
        for name in ["first", "second", "third"] {
            tasks.append(Task {
                try await gate.acquire(.user)
                await order.append(name)
                await gate.release()
            })
            await waitForWaiters(gate, tasks.count)
        }
        #expect(await order.entries.isEmpty)
        await gate.release()
        for task in tasks {
            try await task.value
        }
        #expect(await order.entries == ["first", "second", "third"])
        #expect(await gate.isIdle)
    }

    @Test("A background request is refused while a request is in flight")
    func backgroundRefusedWhileHeld() async throws {
        let gate = ArkhamDBRequestGate()
        try await gate.acquire(.user)
        await #expect(throws: ArkhamDBRequestGate.Busy.self) {
            try await gate.acquire(.background)
        }
        await gate.release()
        try await gate.acquire(.background)
        #expect(await !gate.isIdle)
        await gate.release()
        #expect(await gate.isIdle)
    }

    @Test("A user waiting on a background holder receives the permit directly")
    func backgroundYieldsToWaitingUser() async throws {
        let gate = ArkhamDBRequestGate()
        let order = Order()
        try await gate.acquire(.background)
        let user = Task {
            try await gate.acquire(.user)
            await order.append("user")
            await gate.release()
        }
        await waitForWaiters(gate, 1)
        // The release hands the permit straight to the user, so no background request
        // can slip in between.
        await gate.release()
        try await user.value
        #expect(await order.entries == ["user"])
        #expect(await gate.isIdle)
    }

    @Test("A background request is refused while a user request waits, even if free")
    func backgroundRefusedWhileUserWaits() async throws {
        let gate = ArkhamDBRequestGate()
        try await gate.acquire(.user)
        let user = Task {
            try await gate.acquire(.user)
            await gate.release()
        }
        await waitForWaiters(gate, 1)
        await #expect(throws: ArkhamDBRequestGate.Busy.self) {
            try await gate.acquire(.background)
        }
        await gate.release()
        try await user.value
        #expect(await gate.isIdle)
    }

    @Test("A cancelled waiter is removed, throws, and never takes the permit")
    func cancelledWaiterRemoved() async throws {
        let gate = ArkhamDBRequestGate()
        let order = Order()
        try await gate.acquire(.user)
        let cancelled = Task {
            try await gate.acquire(.user)
            await order.append("cancelled")
            await gate.release()
        }
        await waitForWaiters(gate, 1)
        let next = Task {
            try await gate.acquire(.user)
            await order.append("next")
            await gate.release()
        }
        await waitForWaiters(gate, 2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await gate.waitingCount == 1)
        await gate.release()
        try await next.value
        #expect(await order.entries == ["next"])
        #expect(await gate.isIdle)
    }

    @Test("A cancelled waiter on the only holder leaves the gate free after release")
    func cancelledOnlyWaiter() async throws {
        let gate = ArkhamDBRequestGate()
        try await gate.acquire(.user)
        let waiter = Task { try await gate.acquire(.user) }
        await waitForWaiters(gate, 1)
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await gate.waitingCount == 0)
        await gate.release()
        #expect(await gate.isIdle)
    }

    @Test("An already cancelled task never waits or takes the permit")
    func alreadyCancelled() async throws {
        let gate = ArkhamDBRequestGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire(.user)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await gate.isIdle)
    }
}
