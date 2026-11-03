@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The saved-deck reload awaited inside `applyWriteBack` can outlive the session; nothing
/// after it may write into a session that went stale meanwhile.
@Suite("ArkhamDB write-back stale session after a saved-deck reload")
@MainActor
struct ArkhamDBWriteBackStaleSessionTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckB = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
    private let deckC = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
    private let sentinel = 99
    /// Each test gets a fresh suite instance, so a fresh session.
    private let session = Session()

    private final class Session {
        var isCurrent = true
    }

    /// Loads `rows`, seeds the skipped-row sentinel, and makes the session stale as soon as
    /// saved decks are reloaded.
    private func loaded(
        _ rows: [ArkhamDBWriteBackStatus], then responses: [(Int, Data)]
    ) async throws -> (ArkhamDBViewModel, ArkhamDBScriptedTransport) {
        let session = session
        let transport = try ArkhamDBScriptedTransport(
            [(200, writeBackStatusData(rows))] + responses
        )
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            contextValidator: { _ in session.isCurrent },
            supportsWriteBack: true, savedDecksChanged: { session.isCurrent = false }
        )
        await model.refreshStatus()
        #expect(session.isCurrent)
        model.skippedWriteBackCount = sentinel
        return (model, transport)
    }

    @Test("A status refresh whose reload made the session stale writes nothing afterwards")
    func statusRefreshStopsAfterStaleReload() async throws {
        let refreshed = try ContractJSON.encode(ArkhamDBLinkStatus(
            linked: true, remoteAccountId: "7", remoteAccountName: "Agnes",
            tokenExpiry: nil, linkedAt: nil, writeBackEnabledDeckCount: 1,
            deckLinks: [writeBackRow(deckA, state: .pending, resulting: deckB)],
            skippedDeckLinkCount: 3
        ))
        let (model, _) = try await loaded(
            [writeBackRow(deckA, state: .pending)], then: [(200, refreshed)]
        )
        await model.refreshStatus()
        #expect(!session.isCurrent)
        #expect(model.skippedWriteBackCount == sentinel)
        #expect(model.message == nil)
    }

    @Test("A resolution whose reload made the session stale is skipped, not succeeded")
    func resolutionStopsAfterStaleReload() async throws {
        // deckB's new resulting deck triggers the reload; deckA's own row is still pending,
        // so only a skipped outcome removes deckA's tracking.
        let response = try ContractJSON.encode([
            writeBackRow(deckA, state: .pending),
            writeBackRow(deckB, resulting: deckC),
        ])
        let (model, transport) = try await loaded(
            [writeBackRow(deckA, state: .conflict, reason: .remoteChanged), writeBackRow(deckB)],
            then: [(200, response)]
        )
        await model.chooseResolution(.keepRemote, for: deckA)
        #expect(!session.isCurrent)
        #expect(await transport.requests.count == 2)
        #expect(model.skippedWriteBackCount == sentinel)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        #expect(model.message == nil)
    }
}
