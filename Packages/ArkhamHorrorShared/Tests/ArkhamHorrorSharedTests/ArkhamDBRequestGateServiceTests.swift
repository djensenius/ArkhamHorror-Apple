@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
private final class SessionFlag {
    var isCurrent = true
}

@Suite("ArkhamDB request gate in the service", .timeLimit(.minutes(1)))
@MainActor
struct ArkhamDBRequestGateServiceTests {
    private func waitForWaiters(_ gate: ArkhamDBRequestGate, _ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await gate.waitingCount < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(count) gate waiters")
                return
            }
            await Task.yield()
        }
    }

    @Test("A queued request whose session went stale while waiting sends nothing")
    func staleWhileQueuedSendsNothing() async throws {
        let transport = try GateRoutingTransport([
            "status": [(200, writeBackStatusData([]))],
        ])
        let service = ArkhamDBService(transport: transport)
        await transport.hold(0)
        let first = Task { try await service.status(on: .hosted, token: "app-token") }
        await transport.waitUntilHeld(0)

        let flag = SessionFlag()
        let check: @Sendable () async throws -> Void = { @MainActor in
            guard flag.isCurrent else { throw GameLifecycleTokenAccessError.stale }
        }
        let queued = Task {
            try await ArkhamDBService.$sendCheck.withValue(check) {
                try await service.status(on: .hosted, token: "app-token")
            }
        }
        await waitForWaiters(service.gate, 1)
        // The session changes while the request waits; it is then admitted.
        flag.isCurrent = false
        await transport.release(0)
        #expect(try await first.value.linked)

        await #expect(throws: GameLifecycleTokenAccessError.self) {
            try await queued.value
        }
        #expect(await transport.requests.count == 1)
        #expect(await service.gate.isIdle)
    }

    @Test("A transport failure releases the permit to the next request")
    func transportFailureReleases() async throws {
        // No "decks" route: the transport throws for the deck list.
        let transport = try GateRoutingTransport([
            "status": [(200, writeBackStatusData([]))],
        ])
        let service = ArkhamDBService(transport: transport)
        await transport.hold(0)
        let failing = Task { try await service.listDecks(on: .hosted, token: "app-token") }
        await transport.waitUntilHeld(0)
        let next = Task { try await service.status(on: .hosted, token: "app-token") }
        await waitForWaiters(service.gate, 1)
        await transport.release(0)

        await #expect(throws: DeckServiceError.transportFailure("ArkhamDB transport failed")) {
            try await failing.value
        }
        #expect(try await next.value.linked)
        #expect(await service.gate.isIdle)

        // And with nothing waiting, a failure leaves the gate free for a later request.
        await #expect(throws: DeckServiceError.self) {
            try await service.listDecks(on: .hosted, token: "app-token")
        }
        #expect(await service.gate.isIdle)
        #expect(try await service.status(on: .hosted, token: "app-token").linked)
        #expect(await transport.routeKeys == ["decks", "status", "decks", "status"])
        #expect(await transport.maxInFlight == 1)
        #expect(await service.gate.isIdle)
    }
}
