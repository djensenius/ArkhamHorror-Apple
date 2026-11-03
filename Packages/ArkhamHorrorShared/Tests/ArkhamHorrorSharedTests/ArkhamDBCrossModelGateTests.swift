@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Answers ArkhamDB routes by path below `/arkham/arkhamdb/` (a route's last scripted
/// answer repeats), can hold chosen requests (counted from 0) open until released, and
/// records the most requests ever in flight at once.
actor GateRoutingTransport: HTTPTransport {
    private var routes: [String: [(Int, Data)]]
    private(set) var requests: [URLRequest] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var heldIndexes: Set<Int> = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(_ routes: [String: [(Int, Data)]]) {
        self.routes = routes
    }

    var routeKeys: [String] {
        requests.map(Self.route)
    }

    func hold(_ indexes: Int...) {
        heldIndexes.formUnion(indexes)
    }

    func waitUntilHeld(_ index: Int) async {
        guard held[index] == nil else { return }
        await withCheckedContinuation { heldWaiters[index] = $0 }
    }

    func release(_ index: Int) {
        held.removeValue(forKey: index)?.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if heldIndexes.contains(index) {
            await withCheckedContinuation { continuation in
                held[index] = continuation
                heldWaiters.removeValue(forKey: index)?.resume()
            }
        }
        let key = Self.route(request)
        guard var answers = routes[key], let (status, data) = answers.first else {
            throw TestFailure()
        }
        if answers.count > 1 {
            answers.removeFirst()
            routes[key] = answers
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        ))
        return (data, response)
    }

    private static func route(_ request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        guard let range = path.range(of: "/arkham/arkhamdb/") else { return path }
        return String(path[range.upperBound...])
    }
}

@Suite("ArkhamDB request gate across view models", .timeLimit(.minutes(1)))
@MainActor
struct ArkhamDBCrossModelGateTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let clock = FakeLiveGameClock()

    private func syncRoute(_ id: DeckID) -> String {
        "decks/\(id.rawValue.uuidString.lowercased())/sync"
    }

    private func signedInModel(
        _ transport: GateRoutingTransport,
        base: ScriptedDeckService,
        choiceTimeout: TimeInterval = 30
    ) async -> AppModel {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(tokens: [ServerProfile.hosted.id: "app-token"]),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [ServerCompatibility.arkhamDBAccountLinkingCapability]
            ))),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: ScriptedGameLifecycleService(),
            deckService: base, arkhamDBService: ArkhamDBService(transport: transport),
            deckSyncTracker: RecordingDeckSyncTracker(),
            deckChoiceSyncTimeout: choiceTimeout
        )
        await model.flowTask?.value
        return model
    }

    private func decksModel(_ model: AppModel, _ context: DeckRequestContext) -> DecksViewModel {
        DecksViewModel(
            profile: .hosted, deckService: model.deckService(on: .hosted),
            tokenProvider: { context }
        )
    }

    /// Yields until `condition` holds; records an issue instead of hanging when it never
    /// does (for example, with the gate bypassed nothing ever waits).
    private func waitUntil(
        _ what: String, _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            await Task.yield()
        }
    }

    private func waitForGateWaiters(_ model: AppModel, _ count: Int) async {
        let gate = model.arkhamDBService.gate
        await waitUntil("\(count) requests wait at the gate") {
            await gate.waitingCount >= count
        }
    }

    private func tick() async {
        await clock.waitUntilSleepPending(1)
        await clock.resumeOldestSleep()
    }

    /// A deck fixture under another ID, so several decks have distinct sync routes.
    private func deck(_ id: DeckID) throws -> (Deck, Data) {
        guard case var .object(fields) = try arkhamDBFixture(JSONValue.self, "importedDeck")
        else { throw TestFailure() }
        fields["id"] = .string(id.rawValue.uuidString.lowercased())
        let data = try ContractJSON.encode(JSONValue.object(fields))
        return try (ContractJSON.decode(Deck.self, from: data), data)
    }

    private struct Tracked {
        let deck: Deck
        let transport: GateRoutingTransport
        let model: AppModel
        let context: DeckRequestContext
        let arkhamDB: ArkhamDBViewModel
    }

    /// Loads a conflict for deckA and submits keep-remote (requests 0 and 1), so the
    /// write-back view model polls status. Status answers "pending" afterwards.
    private func tracked() async throws -> Tracked {
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try GateRoutingTransport([
            "status": [
                (200, writeBackStatusData([
                    writeBackRow(deckA, state: .conflict, reason: .remoteChanged),
                ])),
                (200, writeBackStatusData([writeBackRow(deckA, state: .pending)])),
            ],
            "decks/\(deckA.rawValue.uuidString.lowercased())/resolve-conflict": [
                (200, ContractJSON.encode([writeBackRow(deckA, state: .pending)])),
            ],
            syncRoute(deck.id): [(200, arkhamDBFixtureData("syncedDeck"))],
        ])
        let base = ScriptedDeckService()
        await base.enqueueValidate(.success(DeckValidationSuccess()))
        let model = await signedInModel(transport, base: base)
        let context = try await model.currentDeckRequestContext(for: .hosted)
        await clock.setGated(true)
        let arkhamDB = ArkhamDBViewModel(
            profile: .hosted, service: model.arkhamDBService, authentication: nil,
            tokenProvider: { context }, supportsWriteBack: true, clock: clock
        )
        await arkhamDB.refreshStatus()
        await arkhamDB.chooseResolution(.keepRemote, for: deckA)
        #expect(arkhamDB.awaitingResolutionDeckIDs == [deckA])
        #expect(await transport.requests.count == 2)
        return Tracked(
            deck: deck, transport: transport, model: model, context: context,
            arkhamDB: arkhamDB
        )
    }

    @Test("A poll, a deck sync, a choice sync and a user action never overlap, in order")
    func pollSyncAndUserAction() async throws {
        let tracked = try await tracked()
        let (deck, transport, model) = (tracked.deck, tracked.transport, tracked.model)
        let (context, arkhamDB) = (tracked.context, tracked.arkhamDB)

        // The poll's request (2) is in flight; a deck sync and a choice sync queue.
        await transport.hold(2, 3)
        let poll = Task { await arkhamDB.pollWriteBackStatus() }
        await tick()
        await transport.waitUntilHeld(2)
        let decks = decksModel(model, context)
        let sync = Task { await decks.sync(deck) }
        await waitForGateWaiters(model, 1)
        let choice = Task {
            try await model.syncDeckBeforeChoiceIfNeeded(deck, profile: .hosted, context: context)
        }
        await waitForGateWaiters(model, 2)
        #expect(await transport.requests.count == 3)

        // The poll's permit passes straight to the deck sync (3), which is held.
        await transport.release(2)
        await transport.waitUntilHeld(3)
        #expect(await model.arkhamDBService.gate.waitingCount == 1)
        // The next poll tick finds the gate in use: deferred, no request, no attempt.
        await tick()
        await clock.waitUntilSleepPending(1)
        #expect(await clock.requestedDurations == [30, 60, 60].map { Duration.seconds($0) })
        #expect(await transport.requests.count == 4)

        // A user action queues behind the choice sync, never dropped.
        let user = Task { await arkhamDB.refreshStatus() }
        await waitForGateWaiters(model, 2)
        await transport.release(3)
        await sync.value
        let result = try await choice.value
        await user.value
        #expect(await transport.requests.count == 6)

        // The next tick sends the poll's request only after the user requests.
        await tick()
        await clock.waitUntilSleepPending(1)
        poll.cancel()
        await clock.setGated(false)
        await clock.resumeOldestSleep()
        await poll.value

        let segment = deckA.rawValue.uuidString.lowercased()
        #expect(await transport.routeKeys == [
            "status", "decks/\(segment)/resolve-conflict", "status",
            syncRoute(deck.id), syncRoute(deck.id), "status", "status",
        ])
        #expect(await transport.maxInFlight == 1)
        #expect(await clock.requestedDurations == [30, 60, 60, 120].map { Duration.seconds($0) })
        #expect(decks.syncState(for: deck) == .succeeded(deckSyncSuccessMessage()))
        #expect(result.didAttemptSync)
        #expect(result.note == deckSyncSuccessMessage())
        #expect(arkhamDB.message == nil)
        #expect(!arkhamDB.isBusy)
        #expect(await model.arkhamDBService.gate.isIdle)
    }

    @Test("A choice sync whose timeout fires while queued sends nothing and falls back")
    func queuedChoiceSyncTimesOut() async throws {
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try GateRoutingTransport([
            syncRoute(deck.id): [(200, arkhamDBFixtureData("syncedDeck"))],
        ])
        let base = ScriptedDeckService()
        await base.enqueueValidate(.success(DeckValidationSuccess()))
        let model = await signedInModel(transport, base: base, choiceTimeout: 0.2)
        let context = try await model.currentDeckRequestContext(for: .hosted)
        await transport.hold(0)
        let decks = decksModel(model, context)
        let sync = Task { await decks.sync(deck) }
        await transport.waitUntilHeld(0)

        let result = try await model.syncDeckBeforeChoiceIfNeeded(
            deck, profile: .hosted, context: context
        )
        #expect(result.deck == deck)
        #expect(result.didAttemptSync)
        #expect(result.note == deckSyncStaleFallbackMessage())
        #expect(await model.arkhamDBService.gate.waitingCount == 0)
        #expect(await transport.requests.count == 1)

        await transport.release(0)
        await sync.value
        #expect(decks.syncState(for: deck) == .succeeded(deckSyncSuccessMessage()))
        #expect(await transport.requests.count == 1)
        #expect(await transport.maxInFlight == 1)
        #expect(await model.arkhamDBService.gate.isIdle)
    }

    @Test("Refresh-and-sync of three linked decks sends one sync at a time; all complete")
    func refreshAndSyncSerialized() async throws {
        let ids = (1 ... 3).map {
            DeckID(UUID(uuidString: "00000000-0000-0000-0000-00000000005\($0)")!)
        }
        var loaded: [Deck] = []
        var routes: [String: [(Int, Data)]] = [:]
        for id in ids {
            let (deck, data) = try deck(id)
            loaded.append(deck)
            routes[syncRoute(id)] = [(200, data)]
        }
        let transport = GateRoutingTransport(routes)
        let base = ScriptedDeckService()
        await base.enqueueList(.success(loaded))
        let model = await signedInModel(transport, base: base)
        let context = try await model.currentDeckRequestContext(for: .hosted)
        let decks = decksModel(model, context)
        await transport.hold(0)
        let refresh = Task { await decks.refreshAndSync() }
        await transport.waitUntilHeld(0)
        // All three syncs started; two wait at the gate instead of being sent.
        await waitForGateWaiters(model, 2)
        #expect(await transport.requests.count == 1)
        await transport.release(0)
        await refresh.value

        #expect(await transport.maxInFlight == 1)
        #expect(await Set(transport.routeKeys) == Set(ids.map(syncRoute)))
        #expect(await transport.requests.count == 3)
        for deck in loaded {
            #expect(decks.syncState(for: deck) == .succeeded(deckSyncSuccessMessage()))
        }
        #expect(await base.syncedIDs.isEmpty)
        #expect(await model.arkhamDBService.gate.isIdle)
    }
}
