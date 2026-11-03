@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
private final class ReloadCounter {
    var reloads = 0
}

/// A poll for one deck can be in flight when the user sends a resolution or retry for
/// another. The poll applies that deck's pre-request status, so the new request's
/// completion tracker must not exist until the poll has finished.
@Suite("ArkhamDB write-back polling races", .timeLimit(.minutes(1)))
@MainActor
struct ArkhamDBWriteBackPollRaceTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckB = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
    private let counter = ReloadCounter()
    private let clock = FakeLiveGameClock()

    enum Action {
        case keepRemote, saveAsNew, retry
    }

    private func status(_ rowB: ArkhamDBWriteBackStatus) throws -> Data {
        try writeBackStatusData([writeBackRow(deckA, state: .pending), rowB])
    }

    @Test(
        "A held poll for one deck cannot clear another deck's new tracker",
        arguments: [Action.keepRemote, .saveAsNew, .retry]
    )
    func heldPollKeepsNewTracker(action: Action) async throws {
        let conflictB = writeBackRow(deckB, state: .conflict, reason: .remoteChanged)
        // Retry starts from a failed push; the poll then shows an earlier push finished,
        // which would end a tracker inserted too early.
        let initialB = action == .retry
            ? writeBackRow(deckB, state: .failed, error: "remoteUnavailable") : conflictB
        let polledB = action == .retry ? writeBackRow(deckB, state: .succeeded) : conflictB
        let transport = try PollingTransport([
            (200, writeBackStatusData([
                writeBackRow(deckA, state: .conflict, reason: .remoteChanged), initialB,
            ])),
            (200, ContractJSON.encode([writeBackRow(deckA, state: .pending), initialB])),
            (200, status(polledB)),
            (200, ContractJSON.encode([
                writeBackRow(deckA, state: .pending), writeBackRow(deckB, state: .pending),
            ])),
            (200, status(writeBackRow(deckB, state: .succeeded))),
        ])
        await clock.setGated(true)
        let counter = counter
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            supportsWriteBack: true, savedDecksChanged: { counter.reloads += 1 },
            clock: clock
        )
        await model.refreshStatus()
        await model.chooseResolution(.keepRemote, for: deckA)
        let episode = model.writeBackPollEpisode
        #expect(model.awaitingResolutionDeckIDs == [deckA])

        await transport.hold(request: 2)
        let poll = Task { await model.pollWriteBackStatus() }
        await clock.waitUntilSleepPending(1)
        await clock.resumeOldestSleep()
        await transport.waitUntilHeld()

        let user: Task<Void, Never>
        switch action {
        case .keepRemote:
            user = Task { await model.chooseResolution(.keepRemote, for: deckB) }
        case .saveAsNew:
            model.openResolution(deckB)
            await model.chooseResolution(.saveAsNew, for: deckB)
            user = Task { await model.confirmPendingResolution() }
        case .retry:
            user = Task { await model.retryWriteBack(deckB) }
        }
        while model.statusPollWaiters.isEmpty {
            await Task.yield()
        }
        await transport.release()
        await user.value

        #expect(await transport.requests.count == 4)
        #expect(await transport.maxInFlight == 1)
        #expect(model.awaitingResolutionDeckIDs == [deckA, deckB])
        #expect(model.writeBackPollEpisode == episode + 1)
        #expect(counter.reloads == 0)

        poll.cancel()
        await clock.setGated(false)
        await clock.resumeOldestSleep()
        await poll.value

        await model.refreshStatus()
        #expect(await transport.requests.count == 5)
        #expect(model.awaitingResolutionDeckIDs == [deckA])
        #expect(counter.reloads == 1)
    }
}
