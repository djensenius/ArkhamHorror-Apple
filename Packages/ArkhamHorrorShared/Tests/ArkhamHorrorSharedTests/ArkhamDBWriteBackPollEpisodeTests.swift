@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A new polling episode starts only when a resolution or retry was sent and its deck
/// still awaits completion.
@Suite("ArkhamDB write-back polling episodes")
@MainActor
struct ArkhamDBWriteBackPollEpisodeTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)

    enum Action {
        case retry, keepRemote, saveAsNew, overwrite
    }

    /// Loads `row`, runs `action` against the queued `responses` and returns the episode
    /// change, the awaited decks and the number of requests after the initial load.
    private func run(
        _ action: Action, from row: ArkhamDBWriteBackStatus,
        then responses: [(Int, Data)], busy: Bool = false
    ) async throws -> (episodes: Int, awaiting: Set<DeckID>, requests: Int) {
        let transport = try ArkhamDBScriptedTransport(
            [(200, writeBackStatusData([row]))] + responses
        )
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            supportsWriteBack: true
        )
        await model.refreshStatus()
        let episode = model.writeBackPollEpisode
        model.isBusy = busy
        switch action {
        case .retry:
            await model.retryWriteBack(deckA)
        case .keepRemote:
            await model.chooseResolution(.keepRemote, for: deckA)
        case .saveAsNew, .overwrite:
            model.openResolution(deckA)
            await model.chooseResolution(action == .saveAsNew ? .saveAsNew : .overwrite, for: deckA)
            await model.confirmPendingResolution()
        }
        model.isBusy = false
        return (
            model.writeBackPollEpisode - episode, model.awaitingResolutionDeckIDs,
            await transport.requests.count - 1
        )
    }

    private var failedRow: ArkhamDBWriteBackStatus {
        writeBackRow(deckA, state: .failed, error: "remoteUnavailable")
    }

    private var conflictRow: ArkhamDBWriteBackStatus {
        writeBackRow(deckA, state: .conflict, reason: .remoteChanged)
    }

    private func rows(_ state: ArkhamDBWriteBackState) throws -> Data {
        try ContractJSON.encode([writeBackRow(deckA, state: state)])
    }

    private func status(_ state: ArkhamDBWriteBackState) throws -> Data {
        try writeBackStatusData([writeBackRow(deckA, state: state)])
    }

    @Test("A sent retry or save-as-new still pending starts one episode")
    func sentAndPendingBumps() async throws {
        let retry = try await run(.retry, from: failedRow, then: [(200, rows(.pending))])
        #expect(retry.episodes == 1)
        #expect(retry.awaiting == [deckA])
        #expect(retry.requests == 1)
        let saveAsNew = try await run(.saveAsNew, from: conflictRow, then: [(200, rows(.pending))])
        #expect(saveAsNew.episodes == 1)
        #expect(saveAsNew.awaiting == [deckA])
        #expect(saveAsNew.requests == 1)
    }

    @Test(
        "A failed request whose refreshed status still awaits starts one episode",
        arguments: [Action.retry, .keepRemote, .saveAsNew]
    )
    func failedAndPendingBumps(action: Action) async throws {
        let result = try await run(
            action, from: action == .retry ? failedRow : conflictRow,
            then: [(500, Data()), (200, status(.pending))]
        )
        #expect(result.episodes == 1)
        #expect(result.awaiting == [deckA])
        #expect(result.requests == 2)
    }

    @Test(
        "A request that already completed starts no episode",
        arguments: [Action.retry, .keepRemote, .saveAsNew]
    )
    func completedDoesNotBump(action: Action) async throws {
        let result = try await run(
            action, from: action == .retry ? failedRow : conflictRow,
            then: [(200, rows(.succeeded))]
        )
        #expect(result.episodes == 0)
        #expect(result.awaiting.isEmpty)
        #expect(result.requests == 1)
    }

    @Test(
        "A failed request whose refreshed status completed starts no episode",
        arguments: [Action.retry, .saveAsNew]
    )
    func failedAndCompletedDoesNotBump(action: Action) async throws {
        let result = try await run(
            action, from: action == .retry ? failedRow : conflictRow,
            then: [(500, Data()), (200, status(.succeeded))]
        )
        #expect(result.episodes == 0)
        #expect(result.awaiting.isEmpty)
        #expect(result.requests == 2)
    }

    @Test(
        "Nothing sent (busy or session expired) starts no episode",
        arguments: [Action.retry, .keepRemote, .saveAsNew]
    )
    func skippedDoesNotBump(action: Action) async throws {
        let from = action == .retry ? failedRow : conflictRow
        let busy = try await run(action, from: from, then: [], busy: true)
        #expect(busy.episodes == 0)
        #expect(busy.awaiting.isEmpty)
        #expect(busy.requests == 0)
        let expired = try await run(action, from: from, then: [(401, Data())])
        #expect(expired.episodes == 0)
        #expect(expired.awaiting.isEmpty)
        #expect(expired.requests == 1)
    }

    @Test("Overwrite is not tracked and starts no episode")
    func overwriteDoesNotBump() async throws {
        let result = try await run(.overwrite, from: conflictRow, then: [(200, rows(.pending))])
        #expect(result.episodes == 0)
        #expect(result.awaiting.isEmpty)
        #expect(result.requests == 1)
    }
}
