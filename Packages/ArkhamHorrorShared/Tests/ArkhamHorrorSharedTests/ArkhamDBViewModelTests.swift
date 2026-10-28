@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
final class ArkhamDBStubAuthentication: ArkhamDBAuthenticating {
    var result: Result<URL, any Error>
    var onAuthenticate: () -> Void = {}
    private(set) var urls: [URL] = []

    init(_ result: Result<URL, any Error>) {
        self.result = result
    }

    func authenticate(url: URL) async throws -> URL {
        urls.append(url)
        onAuthenticate()
        return try result.get()
    }
}

@Suite("ArkhamDBViewModel")
@MainActor
struct ArkhamDBViewModelTests {
    private func authentication(
        _ query: String = "result=pending&completion=private-secret"
    ) throws -> ArkhamDBStubAuthentication {
        try ArkhamDBStubAuthentication(
            .success(#require(URL(string: "arkhamhorror://arkhamdb-link?\(query)")))
        )
    }

    private func model(
        _ transport: ArkhamDBScriptedTransport,
        authentication: (any ArkhamDBAuthenticating)? = nil,
        validator: @escaping DecksViewModel.ContextValidator = { _ in true },
        expired: @escaping DecksViewModel.SessionExpiredHandler = { _ in }
    ) -> ArkhamDBViewModel {
        ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: authentication,
            tokenProvider: { arkhamDBTestContext }, contextValidator: validator,
            sessionExpiredHandler: expired
        )
    }

    @Test("A failed first status refresh never leaves Loading on screen", arguments: [0, 501, 502])
    func failedInitialStatus(status: Int) async throws {
        let responses = try status == 0 ? [] : [(status, ContractJSON.encode(
            ArkhamDBError(code: status == 501 ? .disabled : .remoteUnavailable, error: "server detail")
        ))]
        let model = model(ArkhamDBScriptedTransport(responses))
        await model.refreshStatus()
        #expect(!model.isBusy)
        #expect(model.status == nil)
        #expect(model.message != nil)
        #expect(model.statusText == arkhamDBLocalized("statusUnavailable"))
        #expect(model.statusText != arkhamDBLocalized("loading"))
    }

    @Test("Link runs start → browser → authenticated completion → authoritative status")
    func startCompleteStatus() async throws {
        let auth = try authentication()
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("linkStart")), (200, Data("[]".utf8)),
            (200, arkhamDBFixtureData("linkedStatus")),
        ])
        let model = model(transport, authentication: auth)
        await model.link()
        #expect(model.status?.linked == true)
        #expect(model.statusText == "Linked as Investigator")
        #expect(model.message == nil)
        #expect(!model.isBusy)
        #expect(auth.urls.map(\.scheme) == ["https"])
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "GET"])
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/arkham/arkhamdb/link/start", "/api/v1/arkham/arkhamdb/link/complete",
            "/api/v1/arkham/arkhamdb/status",
        ])
        #expect(requests
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token app-token" })
        let completionBody = try #require(requests.dropFirst().first?.httpBody)
        #expect(try ContractJSON.decode(JSONValue.self, from: completionBody) ==
            .object(["completion": .string("private-secret")]))
    }

    @Test(
        "Unexpected successful completion bodies refresh status without resending the secret"
    )
    func unexpectedCompletionBody() async throws {
        let auth = try authentication()
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("linkStart")), (200, Data("unexpected body".utf8)),
            (200, arkhamDBFixtureData("linkedStatus")),
        ])
        let model = model(transport, authentication: auth)
        await model.link()
        #expect(model.status?.linked == true)
        #expect(model.message == nil)
        #expect(await transport.requests.count == 3)
    }

    @Test("Cancelling the authentication session does not complete, fail, or sign out")
    func cancelledSession() async throws {
        let auth = ArkhamDBStubAuthentication(.failure(CancellationError()))
        let transport = try ArkhamDBScriptedTransport([(200, arkhamDBFixtureData("linkStart"))])
        var expiredCount = 0
        let model = model(transport, authentication: auth, expired: { _ in expiredCount += 1 })
        await model.link()
        #expect(auth.urls.count == 1)
        #expect(await transport.requests.count == 1)
        #expect(model.message == nil)
        #expect(model.status == nil)
        #expect(!model.isBusy)
        #expect(expiredCount == 0)
    }

    @Test("Error callbacks are surfaced locally without sending a completion or signing out")
    func errorCallback() async throws {
        for (reason, key) in [
            ("access_denied", "denied"),
            ("link_failed", "failed"),
            ("future", "failed"),
        ] {
            let auth = try authentication("result=error&reason=\(reason)")
            let transport = try ArkhamDBScriptedTransport([(200, arkhamDBFixtureData("linkStart"))])
            var expiredCount = 0
            let model = model(transport, authentication: auth, expired: { _ in expiredCount += 1 })
            await model.link()
            #expect(model.message == arkhamDBLocalized(key))
            #expect(await transport.requests.count == 1)
            #expect(model.status == nil)
            #expect(expiredCount == 0)
        }
    }

    @Test("An insecure authorization URL is rejected before the auth session opens")
    func insecureStartDoesNotOpen() async throws {
        let start = ArkhamDBLinkStartResponse(
            authorizeUrl: "http://example.test/auth",
            expiresAt: "later"
        )
        let auth = try authentication()
        let transport = try ArkhamDBScriptedTransport([(200, ContractJSON.encode(start))])
        let model = model(transport, authentication: auth)
        await model.link()
        #expect(auth.urls.isEmpty)
        #expect(model.message == arkhamDBLocalized("failed"))
        #expect(await transport.requests.count == 1)
    }

    @Test("A late browser callback cannot link into a changed app session")
    func staleCallbackDoesNotComplete() async throws {
        let auth = try authentication()
        let transport = try ArkhamDBScriptedTransport([(200, arkhamDBFixtureData("linkStart"))])
        var current = true
        auth.onAuthenticate = { current = false }
        let model = model(transport, authentication: auth, validator: { _ in current })
        await model.link()
        #expect(await transport.requests.count == 1)
        #expect(model.status == nil)
        #expect(model.message == nil)
    }

    @Test("A 409 prompts relinking but never invokes the app session expiry handler")
    func relinkPromptNotSignOut() async throws {
        let transport = try ArkhamDBScriptedTransport([(
            409,
            arkhamDBFixtureData("tokenExpiredError")
        )])
        var expiredCount = 0
        let model = model(transport, expired: { _ in expiredCount += 1 })
        await model.loadDecks()
        #expect(model.needsRelinking)
        #expect(model.message == arkhamDBLocalized("relinkRequired"))
        #expect(expiredCount == 0)
        #expect(!model.isBusy)
    }

    @Test("Imported decks enter Decks immediately, and remote list state is refreshed")
    func importAppearsInDecks() async throws {
        let remote = try #require(arkhamDBFixture([ArkhamDBRemoteDeckSummary].self, "decks").first)
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("importedDeck")), (200, arkhamDBFixtureData("decks")),
        ])
        let model = model(transport)
        let decks = DecksViewModel(
            profile: .hosted,
            deckService: DeckService(),
            tokenProvider: { arkhamDBTestContext }
        )
        await model.importDeck(remote, onImported: decks.upsert)
        #expect(decks.decks == [deck])
        #expect(model.decks == [remote])
        #expect(model.skippedCount == 0)
        #expect(model.message == nil)
    }

    @Test("Linked status with a null remote name is still Linked; unlink refreshes status")
    func nullNameAndUnlink() async throws {
        var fields = try ContractJSON.decode(
            [String: JSONValue].self,
            from: arkhamDBFixtureData("linkedStatus")
        )
        fields["remoteAccountName"] = .null
        let transport = try ArkhamDBScriptedTransport([
            (200, ContractJSON.encode(fields)), (200, Data("[]".utf8)), (
                200,
                arkhamDBFixtureData("unlinkedStatus")
            ),
        ])
        let model = model(transport)
        await model.refreshStatus()
        #expect(model.statusText == "Linked")
        model.confirmsUnlink = true
        await model.unlink()
        #expect(!model.confirmsUnlink)
        #expect(model.status?.linked == false)
        #expect(model.statusText == "Not linked")
        #expect(model.decks.isEmpty)
    }
}
