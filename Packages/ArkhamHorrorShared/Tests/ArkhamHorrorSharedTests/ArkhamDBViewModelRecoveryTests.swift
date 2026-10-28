@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDBViewModel recovery")
@MainActor
struct ArkhamDBViewModelRecoveryTests {
    private func authentication() throws -> ArkhamDBStubAuthentication {
        try ArkhamDBStubAuthentication(.success(#require(URL(
            string: "arkhamhorror://arkhamdb-link?result=pending&completion=private-secret"
        ))))
    }

    private func model(
        _ transport: ArkhamDBScriptedTransport,
        authentication: (any ArkhamDBAuthenticating)? = nil
    ) -> ArkhamDBViewModel {
        ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: authentication, tokenProvider: { arkhamDBTestContext }
        )
    }

    @Test(
        "Successful relinking reloads an open browser after token expiry or cached decks",
        arguments: [false, true]
    )
    func successfulRelinkReloadsOpenBrowser(cachedDecks: Bool) async throws {
        let replacement = ArkhamDBRemoteDeckSummary(
            id: "98765", name: "New account deck", url: nil, investigatorName: nil,
            lastUpdatedAt: nil, version: nil, linkedLocalDeckId: nil
        )
        let transport = try ArkhamDBScriptedTransport([
            cachedDecks ? (200, arkhamDBFixtureData("decks")) :
                (409, arkhamDBFixtureData("tokenExpiredError")),
            (200, arkhamDBFixtureData("linkStart")), (200, Data("[]".utf8)),
            (200, arkhamDBFixtureData("linkedStatus")),
            (200, ContractJSON.encode([replacement])),
        ])
        let model = try model(transport, authentication: authentication())
        model.isDeckBrowserOpen = true
        await model.loadDecks()
        #expect(model.needsRelinking == !cachedDecks)
        #expect(model.hasLoadedDecks == cachedDecks)
        await model.link()
        #expect(model.status?.linked == true)
        #expect(model.decks == [replacement])
        #expect(model.skippedCount == 0)
        #expect(model.hasLoadedDecks)
        #expect(!model.needsRelinking)
        #expect(model.message == nil)
        #expect(!model.isBusy)
        #expect(await transport.requests.map { $0.url?.lastPathComponent } == [
            "decks", "start", "complete", "status", "decks",
        ])
    }

    @Test("Successful linking invalidates a closed browser's cached list without fetching it")
    func successfulLinkInvalidatesClosedBrowser() async throws {
        let transport = try ArkhamDBScriptedTransport([
            (200, Data("[{}]".utf8)),
            (200, arkhamDBFixtureData("linkStart")), (200, Data("[]".utf8)),
            (200, arkhamDBFixtureData("linkedStatus")),
        ])
        let model = try model(transport, authentication: authentication())
        await model.loadDecks()
        #expect(model.hasLoadedDecks)
        #expect(model.skippedCount == 1)
        await model.link()
        #expect(model.decks.isEmpty)
        #expect(model.skippedCount == 0)
        #expect(!model.hasLoadedDecks)
        #expect(model.message == nil)
        #expect(await transport.requests.count == 4)
    }

    @Test("Successful linking discards old decks even when the subsequent status refresh fails")
    func successfulLinkInvalidatesBeforeStatusRefresh() async throws {
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("decks")),
            (200, arkhamDBFixtureData("linkStart")), (200, Data("[]".utf8)),
            (409, arkhamDBFixtureData("tokenExpiredError")),
        ])
        let model = try model(transport, authentication: authentication())
        model.isDeckBrowserOpen = true
        await model.loadDecks()
        #expect(!model.decks.isEmpty)
        await model.link()
        #expect(model.decks.isEmpty)
        #expect(!model.hasLoadedDecks)
        #expect(model.needsRelinking)
        #expect(model.message == arkhamDBLocalized("relinkRequired"))
        #expect(await transport.requests.count == 4)
    }

    @Test(
        "Cancelled or failed linking does not reload the browser or overwrite its result",
        arguments: ["cancelled", "denied", "completionFailed"]
    )
    func unsuccessfulLinkDoesNotReloadBrowser(result: String) async throws {
        let auth = try authentication()
        if result == "cancelled" {
            auth.result = .failure(CancellationError())
        } else if result == "denied" {
            auth.result = try .success(#require(URL(
                string: "arkhamhorror://arkhamdb-link?result=error&reason=access_denied"
            )))
        }
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("decks")), (200, arkhamDBFixtureData("linkStart")),
            (409, arkhamDBFixtureData("tokenExpiredError")),
        ])
        let model = model(transport, authentication: auth)
        model.isDeckBrowserOpen = true
        await model.loadDecks()
        let cachedDecks = model.decks
        await model.link()
        #expect(model.decks == cachedDecks)
        #expect(model.hasLoadedDecks)
        #expect(!model.isBusy)
        switch result {
        case "cancelled": #expect(model.message == nil)
        case "denied": #expect(model.message == arkhamDBLocalized("denied"))
        default: #expect(model.message == arkhamDBLocalized("relinkRequired"))
        }
        #expect(await transport.requests.count == (result == "completionFailed" ? 3 : 2))
    }

    @Test("Unlink succeeds but a failed status refresh displays status unavailable")
    func successfulUnlinkInvalidatesStatusBeforeFailedRefresh() async throws {
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("linkedStatus")), (200, arkhamDBFixtureData("decks")),
            (204, Data()), (502, Data()),
        ])
        let model = model(transport)
        await model.refreshStatus()
        await model.loadDecks()
        #expect(model.status?.linked == true)
        #expect(!model.decks.isEmpty)
        await model.unlink()
        #expect(model.status == nil)
        #expect(model.statusText == arkhamDBLocalized("statusUnavailable"))
        #expect(model.decks.isEmpty)
        #expect(model.skippedCount == 0)
        #expect(!model.hasLoadedDecks)
        #expect(model.message == DeckServiceError.unexpectedStatus(502).message)
        #expect(!model.isBusy)
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "GET", "DELETE", "GET"])
    }

    @Test("Failed unlink preserves authoritative linked status and cached decks")
    func failedUnlinkPreservesStatus() async throws {
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("linkedStatus")), (200, arkhamDBFixtureData("decks")),
            (502, Data()),
        ])
        let model = model(transport)
        await model.refreshStatus()
        await model.loadDecks()
        let status = model.status
        let decks = model.decks
        await model.unlink()
        #expect(model.status == status)
        #expect(model.status?.linked == true)
        #expect(model.decks == decks)
        #expect(model.hasLoadedDecks)
        #expect(model.message == DeckServiceError.unexpectedStatus(502).message)
        #expect(await transport.requests.count == 3)
    }

    @Test("Successful deck refresh clears relink guidance after linking on another device")
    func successfulDeckRefreshClearsNeedsRelinking() async throws {
        let transport = try ArkhamDBScriptedTransport([
            (409, arkhamDBFixtureData("tokenExpiredError")),
            (200, arkhamDBFixtureData("decks")),
        ])
        let model = model(transport)
        await model.loadDecks()
        #expect(model.needsRelinking)
        #expect(model.message == arkhamDBLocalized("relinkRequired"))
        await model.loadDecks()
        #expect(!model.needsRelinking)
        #expect(model.message == nil)
        #expect(model.hasLoadedDecks)
        #expect(try model.decks == arkhamDBFixture([ArkhamDBRemoteDeckSummary].self, "decks"))
        #expect(model.status == nil)
        #expect(await transport.requests.map { $0.url?.lastPathComponent } == ["decks", "decks"])
    }
}
