@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel card catalog lifecycle")
struct AppModelCardCatalogTests {
    @Test("Card catalog load publishes names for the active profile")
    func successPublishesCatalog() async throws {
        let responses = try cardCatalogResponses(for: .hosted, title: "Hosted Machete")
        let transport = FixtureLocaleCatalogTransport(responses: responses)
        let model = await model(transport: transport)

        model.loadCardCatalogIfNeeded()
        await model.cardCatalogTask?.value

        #expect(try model.cardCatalog?.displayName(for: CardCode("c01020")) == "Hosted Machete")
        #expect(model.cardCatalogFailure == nil)
        #expect(!model.isCardCatalogLoading)
        #expect(model.cardCatalogTask == nil)
    }

    @Test("Card catalog failure records failure without publishing stale names")
    func failurePublishesFailure() async throws {
        let builtInURL = cardCatalogURL(path: "/arkham/cards", on: .hosted, cardPool: "both")
        let responses = [
            builtInURL: response(data: Data(), status: 503, url: builtInURL),
        ]
        let transport = FixtureLocaleCatalogTransport(responses: responses)
        let model = await model(transport: transport)
        model.cardCatalog = try CardCatalogSnapshot(namesByCode: [
            CardCode("c01020"): CardName(title: "Stale", subtitle: nil),
        ])
        model.cardCatalog = nil

        model.loadCardCatalogIfNeeded()
        await model.cardCatalogTask?.value

        #expect(model.cardCatalog == nil)
        #expect(model.cardCatalogFailure == .unexpectedStatus(503))
        #expect(!model.isCardCatalogLoading)
        #expect(model.cardCatalogTask == nil)
    }

    @Test("Old-profile card catalog completion cannot clear or overwrite a newer load")
    func profileSwitchMidLoadIgnoresOldCompletion() async throws {
        let transport = GatedCardCatalogTransport()
        let model = await model(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: ServerProfile.hosted.id,
            transport: transport
        )

        model.loadCardCatalogIfNeeded()
        await transport.waitForRequestCount(1)

        model.selectProfile(sampleCustomProfile)
        model.loadCardCatalogIfNeeded()
        await transport.waitForRequestCount(2)

        let customBuiltInURL = cardCatalogURL(
            path: "/arkham/cards", on: sampleCustomProfile, cardPool: "both"
        )
        let customHomebrewURL = cardCatalogURL(path: "/arkham/homebrew/cards", on: sampleCustomProfile)
        try await transport.resumeOldest(
            matching: customBuiltInURL,
            with: cardCatalogResponse(for: customBuiltInURL, title: "Custom Machete")
        )
        await transport.waitForRequestCount(3)
        await transport.resumeOldest(
            matching: customHomebrewURL,
            with: emptyCardCatalogResponse(for: customHomebrewURL)
        )
        await model.cardCatalogTask?.value

        #expect(try model.cardCatalog?.displayName(for: CardCode("c01020")) == "Custom Machete")
        #expect(model.cardCatalogFailure == nil)
        #expect(!model.isCardCatalogLoading)
        #expect(model.cardCatalogTask == nil)

        let hostedBuiltInURL = cardCatalogURL(
            path: "/arkham/cards", on: .hosted, cardPool: "both"
        )
        let hostedHomebrewURL = cardCatalogURL(path: "/arkham/homebrew/cards", on: .hosted)
        try await transport.resumeOldest(
            matching: hostedBuiltInURL,
            with: cardCatalogResponse(for: hostedBuiltInURL, title: "Old Hosted Machete")
        )
        await transport.waitForRequestCount(4)
        await transport.resumeOldest(
            matching: hostedHomebrewURL,
            with: emptyCardCatalogResponse(for: hostedHomebrewURL)
        )
        await transport.drain()

        #expect(model.selectedProfile.id == sampleCustomProfile.id)
        #expect(try model.cardCatalog?.displayName(for: CardCode("c01020")) == "Custom Machete")
        #expect(model.cardCatalogFailure == nil)
        #expect(!model.isCardCatalogLoading)
        #expect(model.cardCatalogTask == nil)
    }

    @Test("Card catalog service preserves cancellation")
    func serviceCancellationIsNotTransportFailure() async {
        let service = CardCatalogService(transport: FixtureLocaleCatalogTransport(
            responses: [:], cancellationRequestNumber: 1
        ))

        await #expect(throws: CancellationError.self) {
            _ = try await service.load(on: .hosted)
        }
    }

    private func model(
        profiles: [ServerProfile] = [.hosted],
        selectedID: UUID? = ServerProfile.hosted.id,
        transport: any LocaleCatalogTransporting
    ) async -> AppModel {
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: profiles, selectedID: selectedID),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            cardCatalogService: CardCatalogService(transport: transport)
        )
        await model.flowTask?.value
        return model
    }

    private func cardCatalogResponses(
        for profile: ServerProfile,
        title: String
    ) throws -> [URL: LocaleCatalogResponse] {
        let builtInURL = cardCatalogURL(path: "/arkham/cards", on: profile, cardPool: "both")
        let homebrewURL = cardCatalogURL(path: "/arkham/homebrew/cards", on: profile)
        return try [
            builtInURL: cardCatalogResponse(for: builtInURL, title: title),
            homebrewURL: emptyCardCatalogResponse(for: homebrewURL),
        ]
    }

    private func cardCatalogURL(
        path: String,
        on profile: ServerProfile,
        cardPool: String? = nil
    ) -> URL {
        let base = profile.endpointURL(path: path, pin: .current)
        guard cardPool != nil,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        components.queryItems = [URLQueryItem(name: "cardPool", value: cardPool)]
        return components.url ?? base
    }

    private func cardCatalogResponse(for url: URL, title: String) throws -> LocaleCatalogResponse {
        var card = try macheteCardDefJSON()
        card["name"] = .object(["title": .string(title), "subtitle": .null])
        let data = try ContractJSON.encode([JSONValue.object(card)])
        return response(data: data, url: url)
    }

    private func emptyCardCatalogResponse(for url: URL) -> LocaleCatalogResponse {
        response(data: Data("[]".utf8), url: url)
    }

    private func response(
        data: Data,
        status: Int = 200,
        url: URL
    ) -> LocaleCatalogResponse {
        LocaleCatalogResponse(
            statusCode: status,
            contentType: "application/json",
            contentTypeOptions: "nosniff",
            url: url,
            data: data
        )
    }

    private func macheteCardDefJSON() throws -> [String: JSONValue] {
        struct CatalogFixture: Decodable {
            let cards: [JSONValue]
        }
        let url = try #require(Bundle.module.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        let fixture = try ContractJSON.decode(CatalogFixture.self, from: Data(contentsOf: url))
        guard case let .object(card)? = fixture.cards.first else {
            throw TestFailure()
        }
        return card
    }
}

private actor GatedCardCatalogTransport: LocaleCatalogTransporting {
    private struct PendingRequest {
        let url: URL
        let continuation: CheckedContinuation<LocaleCatalogResponse, any Error>
    }

    private var pending: [PendingRequest] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var tasks: [Task<Void, Never>] = []
    private(set) var requests: [URL] = []

    func fetch(_ url: URL, maxBytes _: Int) async throws -> LocaleCatalogResponse {
        requests.append(url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(PendingRequest(url: url, continuation: continuation))
                notifyWaiters()
            }
        } onCancel: {
            // Intentionally ignore cancellation: this fake models a transport that can still
            // produce bytes after the caller has switched profiles, so AppModel's generation
            // and profile tokens must fence the late completion.
        }
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count {
            return
        }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func resumeOldest(matching url: URL, with response: LocaleCatalogResponse) {
        guard let index = pending.firstIndex(where: { $0.url == url }) else {
            Issue.record("No pending card catalog request for \(url.absoluteString)")
            return
        }
        pending.remove(at: index).continuation.resume(returning: response)
    }

    func drain() async {
        while !pending.isEmpty {
            await Task.yield()
        }
    }

    private func notifyWaiters() {
        waiters.removeAll { waiter in
            guard requests.count >= waiter.0 else { return false }
            waiter.1.resume()
            return true
        }
    }
}
