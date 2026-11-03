@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Replays scripted responses, can hold one request (counted from 0) open until
/// released, and records the most requests ever in flight at once.
private actor PollingTransport: HTTPTransport {
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var heldIndex: Int?
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    init(_ responses: [(Int, Data)]) {
        self.responses = responses
    }

    func hold(request index: Int) {
        heldIndex = index
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if index == heldIndex {
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        guard !responses.isEmpty else { throw TestFailure() }
        let (status, data) = responses.removeFirst()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        ))
        return (data, response)
    }
}

@MainActor
private final class Probe {
    var isCurrent = true
    /// The app session generation; a new sign-in hands out contexts with a new one.
    var generation = 1
    var reloads = 0
}

@Suite("ArkhamDB write-back status polling", .timeLimit(.minutes(1)))
@MainActor
struct ArkhamDBWriteBackPollingTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let probe = Probe()
    private let clock = FakeLiveGameClock()

    private var pending: Data {
        get throws { try writeBackStatusData([writeBackRow(deckA, state: .pending)]) }
    }

    private func model(_ transport: PollingTransport) async -> ArkhamDBViewModel {
        await clock.setGated(true)
        let probe = probe
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil,
            tokenProvider: {
                DeckRequestContext(
                    token: "app-token", sessionGeneration: probe.generation,
                    credentialEpoch: 0, globalEpoch: 0
                )
            },
            contextValidator: { probe.isCurrent && $0.sessionGeneration == probe.generation },
            supportsWriteBack: true, savedDecksChanged: { probe.reloads += 1 },
            clock: clock
        )
        await model.refreshStatus()
        return model
    }

    /// Loads a remoteChanged conflict for deckA and submits keep-remote (requests 0 and
    /// 1); `responses` start at request 2.
    private func tracked(
        then responses: [(Int, Data)]
    ) async throws -> (ArkhamDBViewModel, PollingTransport) {
        let transport = try PollingTransport([
            (200, writeBackStatusData([
                writeBackRow(deckA, state: .conflict, reason: .remoteChanged),
            ])),
            (200, ContractJSON.encode([writeBackRow(deckA, state: .pending)])),
        ] + responses)
        let model = await model(transport)
        let episode = model.writeBackPollEpisode
        await model.chooseResolution(.keepRemote, for: deckA)
        #expect(model.awaitingResolutionDeckIDs == [deckA])
        #expect(model.writeBackPollEpisode == episode + 1)
        return (model, transport)
    }

    private func tick() async {
        await clock.waitUntilSleepPending(1)
        await clock.resumeOldestSleep()
    }

    /// Ungates the clock and releases any pending sleep, then awaits the loop. A loop
    /// that wrongly keeps polling then runs out its attempts (failing the request and
    /// duration assertions) instead of hanging.
    private func finish(_ poll: Task<Void, Never>) async {
        await clock.setGated(false)
        await clock.resumeOldestSleep()
        await poll.value
    }

    private func seconds(_ values: Int...) -> [Duration] {
        values.map { .seconds($0) }
    }

    @Test("Polls on the backoff schedule, then stops after six attempts still tracking")
    func scheduleAndAttemptCap() async throws {
        let (model, transport) = try await tracked(then: Array(repeating: (200, pending), count: 6))
        let poll = Task { await model.pollWriteBackStatus() }
        for _ in 0 ..< 5 {
            await tick()
        }
        // `finish` releases the sixth sleep; any seventh would run ungated.
        await finish(poll)
        #expect(await clock.requestedDurations == seconds(30, 60, 120, 240, 300, 300))
        let requests = await transport.requests
        #expect(requests.count == 8)
        #expect(requests.dropFirst(2).allSatisfy {
            $0.httpMethod == "GET" && $0.url?.path == "/api/v1/arkham/arkhamdb/status"
        })
        #expect(model.awaitingResolutionDeckIDs == [deckA])
        #expect(model.writeBackStatus(for: deckA)?.state == .pending)
        #expect(probe.reloads == 0)
    }

    @Test("Completion stops polling and reloads saved decks exactly once")
    func completionStops() async throws {
        let (model, transport) = try await tracked(then: [
            (200, pending),
            (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
        ])
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await tick()
        await finish(poll)
        #expect(await clock.requestedDurations == seconds(30, 60))
        #expect(await transport.requests.count == 4)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        #expect(probe.reloads == 1)
    }

    @Test("A failed poll request uses an attempt and polling continues")
    func failedPollContinues() async throws {
        let (model, transport) = try await tracked(then: [
            (500, Data()),
            (200, writeBackStatusData([writeBackRow(deckA, state: .succeeded)])),
        ])
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await tick()
        await finish(poll)
        #expect(await clock.requestedDurations == seconds(30, 60))
        #expect(await transport.requests.count == 4)
        #expect(probe.reloads == 1)
        #expect(model.message == nil)
    }

    @Test("Nothing awaiting: no sleep and no request")
    func nothingAwaiting() async throws {
        let transport = try PollingTransport([
            (200, writeBackStatusData([writeBackRow(deckA, state: .pending)])),
        ])
        let model = await model(transport)
        await finish(Task { await model.pollWriteBackStatus() })
        #expect(await clock.requestedDurations.isEmpty)
        #expect(await transport.requests.count == 1)
        #expect(model.writeBackPollEpisode == 0)
    }

    @Test("A poll leaves controls enabled; a user request waits for it, never overlapping")
    func userRequestWaitsForPoll() async throws {
        let (model, transport) = try await tracked(then: [(200, pending), (200, pending)])
        await transport.hold(request: 2)
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await transport.waitUntilHeld()
        #expect(!model.isBusy)
        #expect(model.isPollingStatus)
        let user = Task { await model.refreshStatus() }
        // Until the user request waits for the poll, or (if it does not wait) is sent.
        while model.statusPollWaiters.isEmpty, await transport.requests.count < 4 {
            await Task.yield()
        }
        #expect(model.isBusy)
        #expect(await transport.requests.count == 3)
        await transport.release()
        await user.value
        #expect(await transport.requests.count == 4)
        #expect(await transport.maxInFlight == 1)
        #expect(!model.isBusy)
        await clock.waitUntilSleepPending(1)
        poll.cancel()
        await finish(poll)
        #expect(await transport.requests.count == 4)
    }

    @Test("A tick during a user request is deferred without using an attempt")
    func busyTickIsDeferred() async throws {
        let (model, transport) = try await tracked(then: [(200, pending), (200, pending)])
        await transport.hold(request: 2)
        let user = Task { await model.refreshStatus() }
        await transport.waitUntilHeld()
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await clock.waitUntilSleepPending(1)
        #expect(await clock.requestedDurations == seconds(30, 30))
        #expect(await transport.requests.count == 3)
        await transport.release()
        await user.value
        await tick()
        await clock.waitUntilSleepPending(1)
        #expect(await transport.requests.count == 4)
        #expect(await clock.requestedDurations == seconds(30, 30, 60))
        #expect(await transport.maxInFlight == 1)
        poll.cancel()
        await finish(poll)
        #expect(await transport.requests.count == 4)
    }

    @Test("Unlinking stops polling")
    func unlinkStops() async throws {
        let (model, transport) = try await tracked(then: [(204, Data()), (500, Data())])
        let poll = Task { await model.pollWriteBackStatus() }
        await clock.waitUntilSleepPending(1)
        await model.unlink()
        await finish(poll)
        #expect(await transport.requests.count == 4)
        #expect(await clock.requestedDurations == seconds(30))
    }

    /// A new session would hand out a fresh, valid context, so only the previous poll's
    /// context shows that the session changed.
    @Test("A new app session after a poll stops polling without a request")
    func staleContextStops() async throws {
        let (model, transport) = try await tracked(then: [(200, pending), (200, pending)])
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await clock.waitUntilSleepPending(1)
        probe.generation += 1
        await finish(poll)
        #expect(await transport.requests.count == 3)
        #expect(await clock.requestedDurations == seconds(30, 60))
    }

    @Test("A session already stale at the first tick stops polling without a request")
    func staleAtFirstTickStops() async throws {
        let (model, transport) = try await tracked(then: [(200, pending)])
        let poll = Task { await model.pollWriteBackStatus() }
        await clock.waitUntilSleepPending(1)
        probe.isCurrent = false
        await finish(poll)
        #expect(await transport.requests.count == 2)
        #expect(await clock.requestedDurations == seconds(30))
    }

    @Test(
        "Losing write-back stops polling",
        arguments: [
            (409, #"{"code":"writeBackDisabled","error":"disabled"}"#),
            (404, #"{"code":"disabled","error":"disabled"}"#),
            (409, #"{"code":"notLinked","error":"not linked"}"#),
            (404, ""),
        ]
    )
    func capabilityLossStops(status: Int, body: String) async throws {
        let (model, transport) = try await tracked(then: [(status, Data(body.utf8))])
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await finish(poll)
        #expect(await transport.requests.count == 3)
        #expect(await clock.requestedDurations == seconds(30))
    }

    @Test("A status showing the awaited deck opted out stops polling")
    func optedOutStops() async throws {
        let (model, transport) = try await tracked(then: [
            (200, writeBackStatusData([writeBackRow(deckA, enabled: false, state: .pending)])),
        ])
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await finish(poll)
        #expect(await transport.requests.count == 3)
        #expect(await clock.requestedDurations == seconds(30))
    }

    @Test("Cancelling the view task stops polling, during a sleep or a request")
    func cancellationStops() async throws {
        let (model, transport) = try await tracked(then: [(200, pending)])
        await transport.hold(request: 2)
        let poll = Task { await model.pollWriteBackStatus() }
        await tick()
        await transport.waitUntilHeld()
        poll.cancel()
        await transport.release()
        await finish(poll)
        #expect(await transport.requests.count == 3)
        #expect(await clock.requestedDurations == seconds(30))
        #expect(!model.isPollingStatus)

        await clock.setGated(true)
        let second = Task { await model.pollWriteBackStatus() }
        await clock.waitUntilSleepPending(1)
        second.cancel()
        await finish(second)
        #expect(await transport.requests.count == 3)
        #expect(await clock.requestedDurations == seconds(30, 30))
    }
}
