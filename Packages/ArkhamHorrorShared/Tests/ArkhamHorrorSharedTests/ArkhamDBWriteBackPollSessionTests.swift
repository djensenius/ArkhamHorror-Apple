@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
private final class Session {
    /// The app session generation; a new sign-in hands out contexts with a new one.
    var generation = 1
}

/// A user action that waits for an in-flight status poll keeps the context it started
/// with; a session replaced during the wait must not receive its request.
@Suite("ArkhamDB write-back polling and session changes", .timeLimit(.minutes(1)))
@MainActor
struct ArkhamDBWriteBackPollSessionTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckB = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
    private let session = Session()
    private let clock = FakeLiveGameClock()

    enum Action {
        case unlink, keepRemote
    }

    private func model(_ transport: PollingTransport) async -> ArkhamDBViewModel {
        await clock.setGated(true)
        let session = session
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil,
            tokenProvider: {
                DeckRequestContext(
                    token: "app-token", sessionGeneration: session.generation,
                    credentialEpoch: 0, globalEpoch: 0
                )
            },
            contextValidator: { $0.sessionGeneration == session.generation },
            supportsWriteBack: true, clock: clock
        )
        await model.refreshStatus()
        return model
    }

    @Test(
        "An action waiting for a poll is not sent after the app session changes",
        arguments: [Action.unlink, .keepRemote]
    )
    func sessionChangeDuringWait(action: Action) async throws {
        let conflictB = writeBackRow(deckB, state: .conflict, reason: .remoteChanged)
        let pending = try writeBackStatusData([writeBackRow(deckA, state: .pending), conflictB])
        let transport = try PollingTransport([
            (200, writeBackStatusData([
                writeBackRow(deckA, state: .conflict, reason: .remoteChanged), conflictB,
            ])),
            (200, ContractJSON.encode([writeBackRow(deckA, state: .pending), conflictB])),
            (200, pending),
            (204, Data()),
            (200, pending),
        ])
        let model = await model(transport)
        await model.chooseResolution(.keepRemote, for: deckA)
        #expect(model.awaitingResolutionDeckIDs == [deckA])

        await transport.hold(request: 2)
        let poll = Task { await model.pollWriteBackStatus() }
        await clock.waitUntilSleepPending(1)
        await clock.resumeOldestSleep()
        await transport.waitUntilHeld()
        let user = switch action {
        case .unlink: Task { await model.unlink() }
        case .keepRemote: Task { await model.chooseResolution(.keepRemote, for: deckB) }
        }
        while model.statusPollWaiters.isEmpty {
            await Task.yield()
        }
        session.generation += 1
        await transport.release()
        await user.value
        await clock.setGated(false)
        await clock.resumeOldestSleep()
        await poll.value

        #expect(await transport.requests.count == 3)
        #expect(model.message == nil)
        #expect(model.awaitingResolutionDeckIDs == [deckA])
        #expect(model.status?.linked == true)
        #expect(!model.isBusy)
    }
}
