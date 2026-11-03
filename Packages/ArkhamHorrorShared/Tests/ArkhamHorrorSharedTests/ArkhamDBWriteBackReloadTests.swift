@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB write-back saved-deck reloads")
@MainActor
struct ArkhamDBWriteBackReloadTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckB = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)

    private func loaded(
        _ rows: [ArkhamDBWriteBackStatus],
        then responses: [(Int, Data)],
        savedDecksChanged: @escaping @MainActor () async -> Void
    ) async throws -> (ArkhamDBViewModel, ArkhamDBScriptedTransport) {
        let transport = try ArkhamDBScriptedTransport(
            [(200, writeBackStatusData(rows))] + responses
        )
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            supportsWriteBack: true, savedDecksChanged: savedDecksChanged
        )
        await model.refreshStatus()
        return (model, transport)
    }

    @Test(
        "Saved decks reload once, when a later status shows the resolution completed",
        arguments: [ArkhamDBWriteBackResolution.keepRemote, .saveAsNew]
    )
    func reloadOnCompletion(resolution: ArkhamDBWriteBackResolution) async throws {
        var reloads = 0
        let pending = writeBackRow(deckA, state: .pending)
        let (model, transport) = try await loaded(
            [writeBackRow(deckA, state: .conflict, reason: .campaignChanged)],
            then: [
                (200, ContractJSON.encode([pending])),
                (200, writeBackStatusData([pending])),
                (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
                (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
            ],
            savedDecksChanged: { reloads += 1 }
        )
        model.openResolution(deckA)
        await model.chooseResolution(resolution, for: deckA)
        await model.confirmPendingResolution()
        #expect(await transport.requests.count == 2)
        #expect(reloads == 0)
        await model.refreshStatus()
        #expect(reloads == 0)
        await model.refreshStatus()
        #expect(reloads == 1)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        await model.refreshStatus()
        #expect(reloads == 1)
    }

    @Test("A new or changed resultingLocalDeckId reloads saved decks once")
    func reloadOnResultingDeck() async throws {
        var reloads = 0
        let (model, _) = try await loaded(
            [writeBackRow(deckA, state: .pending), writeBackRow(deckB)],
            then: [
                (200, writeBackStatusData([
                    writeBackRow(deckA, state: .pending, resulting: deckB), writeBackRow(deckB),
                ])),
                (200, writeBackStatusData([
                    writeBackRow(deckA, state: .pending, resulting: deckB), writeBackRow(deckB),
                ])),
            ],
            savedDecksChanged: { reloads += 1 }
        )
        #expect(reloads == 0)
        await model.refreshStatus()
        #expect(reloads == 1)
        await model.refreshStatus()
        #expect(reloads == 1)
    }

    /// Submits keep-remote for deckA from a conflict; the response is still pending.
    private func tracking(
        then responses: [(Int, Data)], savedDecksChanged: @escaping @MainActor () async -> Void
    ) async throws -> ArkhamDBViewModel {
        let (model, _) = try await loaded(
            [writeBackRow(deckA, state: .conflict, reason: .remoteChanged)],
            then: [(200, ContractJSON.encode([writeBackRow(deckA, state: .pending)]))]
                + responses,
            savedDecksChanged: savedDecksChanged
        )
        await model.chooseResolution(.keepRemote, for: deckA)
        #expect(model.awaitingResolutionDeckIDs == [deckA])
        return model
    }

    @Test("Pending to running does not reload; running to succeeded reloads once")
    func runningIsNotCompletion() async throws {
        var reloads = 0
        let model = try await tracking(then: [
            (200, writeBackStatusData([writeBackRow(deckA, state: .running)])),
            (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
        ], savedDecksChanged: { reloads += 1 })
        await model.refreshStatus()
        #expect(reloads == 0)
        await model.refreshStatus()
        #expect(reloads == 1)
    }

    @Test("A send skipped while busy leaves no tracking, so completion does not reload")
    func skippedSendIsNotTracked() async throws {
        var reloads = 0
        let (model, transport) = try await loaded(
            [writeBackRow(deckA, state: .conflict, reason: .remoteChanged)],
            then: [(200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)]))],
            savedDecksChanged: { reloads += 1 }
        )
        model.isBusy = true
        await model.chooseResolution(.keepRemote, for: deckA)
        model.isBusy = false
        #expect(await transport.requests.count == 1)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        await model.refreshStatus()
        #expect(reloads == 0)
    }

    @Test("A tracked row that disappears is dropped and does not reload if it returns done")
    func disappearedRowIsDropped() async throws {
        var reloads = 0
        let model = try await tracking(then: [
            (200, writeBackStatusData([])),
            (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
        ], savedDecksChanged: { reloads += 1 })
        await model.refreshStatus()
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        await model.refreshStatus()
        #expect(reloads == 0)
    }

    @Test("Unlinking clears tracking even when the follow-up status read fails")
    func unlinkClearsTracking() async throws {
        let model = try await tracking(
            then: [(204, Data()), (500, Data())], savedDecksChanged: {}
        )
        await model.unlink()
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
    }

    @Test("Without the write-back capability, applying status clears any tracking")
    func capabilityLossClearsTracking() async throws {
        var reloads = 0
        let transport = try ArkhamDBScriptedTransport([
            (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
        ])
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            supportsWriteBack: false, savedDecksChanged: { reloads += 1 }
        )
        model.awaitingResolutionDeckIDs = [deckA]
        await model.refreshStatus()
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        #expect(reloads == 0)
    }
}
