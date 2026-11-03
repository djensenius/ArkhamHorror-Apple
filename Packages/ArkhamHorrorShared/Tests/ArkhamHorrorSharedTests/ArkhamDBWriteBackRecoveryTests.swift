@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Replays scripted responses; a hook can run before the response to a given request
/// (counted from 0), e.g. to throw cancellation or make the app session stale.
private actor HookedTransport: HTTPTransport {
    private var responses: [(Int, Data)]
    private let hooks: [Int: @Sendable () async throws -> Void]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, Data)], hooks: [Int: @Sendable () async throws -> Void] = [:]) {
        self.responses = responses
        self.hooks = hooks
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        try await hooks[index]?()
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
private final class Session {
    var isCurrent = true
    var expiries = 0
    var reloads = 0
}

@Suite("ArkhamDB write-back recovery refresh and new deck rows")
@MainActor
struct ArkhamDBWriteBackRecoveryTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckC = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
    private let deckD = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!)
    private let disabled = Data(#"{"code":"writeBackDisabled","error":"disabled"}"#.utf8)
    private let conflict = Data(#"{"code":"conflict","error":"conflict"}"#.utf8)
    private let session = Session()

    /// Loads `rows`, then queues `responses`; `hooks` index the requests after the load.
    private func loaded(
        _ rows: [ArkhamDBWriteBackStatus],
        then responses: [(Int, Data)],
        hooks: [Int: @Sendable () async throws -> Void] = [:]
    ) async throws -> (ArkhamDBViewModel, HookedTransport) {
        let session = session
        let transport = try HookedTransport(
            [(200, writeBackStatusData(rows))] + responses,
            hooks: Dictionary(uniqueKeysWithValues: hooks.map { ($0.key + 1, $0.value) })
        )
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            contextValidator: { _ in session.isCurrent },
            sessionExpiredHandler: { _ in session.expiries += 1 },
            supportsWriteBack: true, savedDecksChanged: { session.reloads += 1 }
        )
        await model.refreshStatus()
        return (model, transport)
    }

    /// A failed push whose Retry gets a 409 (`writeBackDisabled` unless `rejection` is
    /// given) and then the given recovery refresh.
    private func retried(
        rejection: Data? = nil,
        refresh: [(Int, Data)], hook: (@Sendable () async throws -> Void)? = nil
    ) async throws -> (ArkhamDBViewModel, HookedTransport) {
        let (model, transport) = try await loaded(
            [writeBackRow(deckA, state: .failed, error: "remoteUnavailable")],
            then: [(409, rejection ?? disabled)] + refresh,
            hooks: hook.map { [1: $0] } ?? [:]
        )
        await model.retryWriteBack(deckA)
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "POST", "GET"])
        return (model, transport)
    }

    @Test("Session expiry on the recovery refresh signs out instead of showing the 409")
    func expiryDuringRecovery() async throws {
        let (model, _) = try await retried(refresh: [(401, Data())])
        #expect(session.expiries == 1)
        #expect(model.message == DeckServiceError.sessionExpired.message)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
    }

    @Test("Cancellation during the recovery refresh is not reported as the 409")
    func cancellationDuringRecovery() async throws {
        let (model, _) = try await retried(refresh: [], hook: { throw CancellationError() })
        #expect(model.message == nil)
        #expect(session.expiries == 0)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
    }

    @Test("A session gone stale during the recovery refresh skips the write-back")
    func staleDuringRecovery() async throws {
        let session = session
        let (model, _) = try await retried(
            refresh: [(200, writeBackStatusData([writeBackRow(deckA, state: .cancelled)]))],
            hook: { await MainActor.run { session.isCurrent = false } }
        )
        #expect(model.message == nil)
        #expect(model.awaitingResolutionDeckIDs.isEmpty)
        #expect(model.writeBackStatus(for: deckA)?.state == .failed)
    }

    @Test("An ordinary recovery refresh failure still shows the write-back error")
    func ordinaryRecoveryFailure() async throws {
        let (model, _) = try await retried(refresh: [(500, Data())])
        #expect(model.message == arkhamDBLocalized("writeBack.error.disabled"))
        #expect(session.expiries == 0)
        #expect(model.awaitingResolutionDeckIDs == [deckA])
    }

    @Test("A conflict whose recovery refresh fails does not claim status was refreshed")
    func conflictWithFailedRefresh() async throws {
        // A 500, and a transport error (no scripted response), on the recovery refresh.
        for refresh in [[(500, Data())], []] {
            let (model, _) = try await retried(rejection: conflict, refresh: refresh)
            #expect(model.message == arkhamDBLocalized("writeBack.error.conflictRefreshFailed"))
            #expect(model.message == "ArkhamDB can't apply that choice to this deck now, "
                + "and the latest status couldn't be loaded. Refresh status and try again.")
            #expect(model.message != arkhamDBLocalized("writeBack.error.conflict"))
            #expect(model.awaitingResolutionDeckIDs == [deckA])
        }
        #expect(session.expiries == 0)
    }

    @Test("A conflict whose recovery refresh succeeds says status was refreshed")
    func conflictWithRefresh() async throws {
        let (model, _) = try await retried(
            rejection: conflict,
            refresh: [(200, writeBackStatusData([writeBackRow(deckA, state: .cancelled)]))]
        )
        #expect(model.message == arkhamDBLocalized("writeBack.error.conflict"))
        #expect(model.message
            == "ArkhamDB can't apply that choice to this deck now. Status was refreshed.")
        #expect(model.writeBackStatus(for: deckA)?.state == .cancelled)
    }

    @Test("A save-as-new clone that appears as a new row reloads saved decks once")
    func cloneAppearsAsNewRow() async throws {
        // Campaign X is saved as new; campaign Y's queued push keeps deckA pending with
        // an unchanged resulting deck, so the clone (deckD) only shows up as its own row.
        let pending = writeBackRow(deckA, state: .pending, resulting: deckC)
        let withClone = try writeBackStatusData([pending, writeBackRow(deckD)])
        let (model, _) = try await loaded(
            [writeBackRow(deckA, state: .conflict, reason: .campaignChanged, resulting: deckC)],
            then: [
                (200, ContractJSON.encode([pending])), (200, writeBackStatusData([pending])),
                (200, withClone), (200, withClone),
            ]
        )
        #expect(session.reloads == 0)
        model.openResolution(deckA)
        await model.chooseResolution(.saveAsNew, for: deckA)
        await model.confirmPendingResolution()
        await model.refreshStatus()
        #expect(session.reloads == 0)
        await model.refreshStatus()
        #expect(session.reloads == 1)
        #expect(model.writeBackStatus(for: deckD) == writeBackRow(deckD))
        await model.refreshStatus()
        #expect(session.reloads == 1)
    }

    @Test("A clone already named as a resulting deck does not reload again as its own row")
    func knownCloneRowDoesNotReload() async throws {
        let named = writeBackRow(deckA, state: .pending, resulting: deckC)
        let (model, _) = try await loaded(
            [writeBackRow(deckA, state: .pending)],
            then: [
                (200, writeBackStatusData([named])),
                (200, writeBackStatusData([named, writeBackRow(deckC)])),
            ]
        )
        await model.refreshStatus()
        #expect(session.reloads == 1)
        await model.refreshStatus()
        #expect(model.writeBackStatus(for: deckC) == writeBackRow(deckC))
        #expect(session.reloads == 1)
    }
}
