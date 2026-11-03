@testable import ArkhamHorrorShared
import Foundation
import Testing

private func row(
    _ id: DeckID,
    enabled: Bool = true,
    state: ArkhamDBWriteBackState = .idle,
    reason: ArkhamDBWriteBackConflictReason? = nil,
    error: String? = nil,
    resulting: DeckID? = nil,
    spentXpSynced: Bool = false
) -> ArkhamDBWriteBackStatus {
    ArkhamDBWriteBackStatus(
        localDeckId: id, remoteDeckId: "123", enabled: enabled, state: state,
        pushId: nil, campaignKey: nil, error: error,
        conflict: reason.map {
            ArkhamDBWriteBackConflict(
                reason: $0, lastSyncedDateUpdate: nil, lastSyncedVersion: nil,
                remoteDateUpdate: nil, remoteVersion: nil
            )
        },
        resultingLocalDeckId: resulting, spentXpSynced: spentXpSynced
    )
}

private func statusData(_ rows: [ArkhamDBWriteBackStatus]) throws -> Data {
    try ContractJSON.encode(ArkhamDBLinkStatus(
        linked: true, remoteAccountId: "7", remoteAccountName: "Agnes",
        tokenExpiry: nil, linkedAt: nil,
        writeBackEnabledDeckCount: rows.count { $0.enabled },
        deckLinks: rows, skippedDeckLinkCount: 0
    ))
}

private func body(_ request: URLRequest) throws -> JSONValue {
    try ContractJSON.decode(JSONValue.self, from: #require(request.httpBody))
}

@Suite("ArkhamDB write-back view model")
@MainActor
struct ArkhamDBWriteBackViewModelTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckB = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
    private let base = "/api/v1/arkham/arkhamdb/decks/00000000-0000-0000-0000-0000000000a1"

    private func model(
        _ transport: ArkhamDBScriptedTransport,
        supportsWriteBack: Bool = true,
        savedDecksChanged: @escaping @MainActor () async -> Void = {}
    ) -> ArkhamDBViewModel {
        ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            supportsWriteBack: supportsWriteBack, savedDecksChanged: savedDecksChanged
        )
    }

    /// A model that has loaded `rows` from status, with `responses` queued after it.
    private func loaded(
        _ rows: [ArkhamDBWriteBackStatus],
        then responses: [(Int, Data)],
        savedDecksChanged: @escaping @MainActor () async -> Void = {}
    ) async throws -> (ArkhamDBViewModel, ArkhamDBScriptedTransport) {
        let transport = try ArkhamDBScriptedTransport([(200, statusData(rows))] + responses)
        let model = model(transport, savedDecksChanged: savedDecksChanged)
        await model.refreshStatus()
        #expect(model.writeBackStatus(for: rows[0].localDeckId) == rows[0])
        return (model, transport)
    }

    @Test("The toggle sends PUT write-back and updates every row from the response")
    func toggle() async throws {
        let (model, transport) = try await loaded(
            [row(deckA, enabled: false), row(deckB, state: .pending)],
            then: [(200, ContractJSON.encode([row(deckA, state: .pending), row(deckB)]))]
        )
        #expect(model.writeBackStatus(for: deckA)?.showsSpentXpNote == false)
        await model.setWriteBack(deckA, enabled: true)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "\(base)/write-back")
        #expect(try body(request) == .object(["enabled": .bool(true)]))
        #expect(model.writeBackStatus(for: deckA) == row(deckA, state: .pending))
        #expect(model.writeBackStatus(for: deckB) == row(deckB))
        #expect(model.writeBackStatus(for: deckA)?.showsSpentXpNote == true)
        #expect(model.message == nil)
    }

    @Test("Only the resolutions the server accepts are offered for each reason")
    func allowedActions() {
        let expected: [(ArkhamDBWriteBackConflictReason, [ArkhamDBWriteBackResolution])] = [
            (.remoteChanged, [.keepRemote, .overwrite, .saveAsNew]),
            (.campaignChanged, [.keepRemote, .saveAsNew]),
            (.pushUncertain, [.keepRemote, .saveAsNew]),
            (.targetAlreadyLinked, [.keepRemote, .saveAsNew]),
            (.boundaryUndone, []),
            (.accountChanged, []),
            (.unknown("future"), []),
        ]
        for (reason, resolutions) in expected {
            let status = row(deckA, state: .conflict, reason: reason)
            #expect(status.allowedResolutions == resolutions)
            #expect(!status.canRetry)
            #expect(status.statusText == arkhamDBLocalized(reason.messageKey))
        }
        // The server refuses retry and resolution for opted-out decks.
        #expect(row(deckA, enabled: false, state: .conflict, reason: .remoteChanged)
            .allowedResolutions.isEmpty)
        #expect(row(deckA, state: .failed).canRetry)
        #expect(!row(deckA, enabled: false, state: .failed).canRetry)
        #expect(!row(deckA, state: .pending).canRetry)
        #expect(row(deckA, state: .failed, error: "pushUncertain").statusText
            == arkhamDBLocalized("writeBack.state.failedUncertain"))
        // An unknown future state is unsupported even with a resolvable-looking conflict.
        let future = row(deckA, state: .unknown("reconciling"), reason: .remoteChanged)
        #expect(future.allowedResolutions.isEmpty)
        #expect(!future.canRetry)
        #expect(future.statusText == arkhamDBLocalized("writeBack.state.unknown"))
        // The spent-XP note never trusts a contract-violating spentXpSynced=true.
        #expect(row(deckA, spentXpSynced: true).showsSpentXpNote)
        #expect(!row(deckA, enabled: false, spentXpSynced: true).showsSpentXpNote)
    }

    @Test(
        "Overwrite and save-as-new need confirmation; cancelling sends nothing",
        arguments: [ArkhamDBWriteBackResolution.overwrite, .saveAsNew]
    )
    func confirmation(resolution: ArkhamDBWriteBackResolution) async throws {
        let conflict = row(deckA, state: .conflict, reason: .remoteChanged)
        let (model, transport) = try await loaded(
            [conflict], then: [(200, ContractJSON.encode([row(deckA, state: .pending)]))]
        )
        model.openConflict(deckA)
        #expect(model.resolvingDeckID == deckA)
        await model.chooseResolution(resolution, for: deckA)
        #expect(model.pendingConfirmation == ArkhamDBPendingResolution(
            deckID: deckA, resolution: resolution
        ))
        model.cancelPendingResolution()
        #expect(model.pendingConfirmation == nil)
        await model.confirmPendingResolution()
        #expect(await transport.requests.count == 1)
        #expect(model.writeBackStatus(for: deckA) == conflict)

        await model.chooseResolution(resolution, for: deckA)
        #expect(await transport.requests.count == 1)
        await model.confirmPendingResolution()
        let request = try #require(await transport.requests.last)
        #expect(await transport.requests.count == 2)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "\(base)/resolve-conflict")
        #expect(try body(request) == .object([
            "resolution": .string(resolution.rawValue), "confirmed": .bool(true),
        ]))
        #expect(model.writeBackStatus(for: deckA) == row(deckA, state: .pending))
        #expect(model.resolvingDeckID == nil)
    }

    @Test("Keep-remote is sent at once; a refused resolution is never sent or confirmed")
    func keepRemoteAndRefused() async throws {
        let (model, transport) = try await loaded(
            [row(deckA, state: .conflict, reason: .campaignChanged)],
            then: [(200, ContractJSON.encode([row(deckA, state: .pending)]))]
        )
        await model.chooseResolution(.overwrite, for: deckA)
        #expect(model.pendingConfirmation == nil)
        #expect(await transport.requests.count == 1)
        await model.chooseResolution(.keepRemote, for: deckA)
        let request = try #require(await transport.requests.last)
        #expect(try body(request) == .object([
            "resolution": .string("keepRemote"), "confirmed": .bool(false),
        ]))
        #expect(model.writeBackStatus(for: deckA)?.state == .pending)
    }

    @Test(
        "Accounting fences are dead ends: no retry, resolution or confirmation is sent",
        arguments: [ArkhamDBWriteBackConflictReason.boundaryUndone, .accountChanged]
    )
    func deadEnds(reason: ArkhamDBWriteBackConflictReason) async throws {
        let fenced = row(deckA, state: .conflict, reason: reason)
        let (model, transport) = try await loaded([fenced], then: [])
        let status = try #require(model.writeBackStatus(for: deckA))
        #expect(status.blockedReason == reason)
        #expect(status.allowedResolutions.isEmpty)
        #expect(!status.canRetry)
        // The fence survives opting out, and is still shown as blocked.
        #expect(row(deckA, enabled: false, state: .conflict, reason: reason).blockedReason
            == reason)
        #expect(row(deckA, state: .conflict, reason: .remoteChanged).blockedReason == nil)
        model.openConflict(deckA)
        #expect(model.resolvingStatus == fenced)
        await model.retryWriteBack(deckA)
        for resolution in ArkhamDBWriteBackResolution.allCases {
            await model.chooseResolution(resolution, for: deckA)
        }
        #expect(model.pendingConfirmation == nil)
        #expect(await transport.requests.count == 1)
    }

    @Test("Saved decks are refreshed after save-as-new only")
    func refreshAfterSaveAsNew() async throws {
        var refreshes = 0
        let response = try ContractJSON.encode([row(deckA, state: .pending)])
        let (model, _) = try await loaded(
            [row(deckA, state: .conflict, reason: .remoteChanged)],
            then: [(200, response)],
            savedDecksChanged: { refreshes += 1 }
        )
        await model.chooseResolution(.keepRemote, for: deckA)
        #expect(refreshes == 0)

        let (saving, _) = try await loaded(
            [row(deckA, state: .conflict, reason: .campaignChanged)],
            then: [(200, response)],
            savedDecksChanged: { refreshes += 1 }
        )
        await saving.chooseResolution(.saveAsNew, for: deckA)
        #expect(refreshes == 0)
        await saving.confirmPendingResolution()
        #expect(refreshes == 1)
    }

    @Test("A failed write-back call refreshes status and shows a specific message")
    func refreshAfterError() async throws {
        let refreshed = row(deckA, enabled: false, state: .cancelled)
        let (model, transport) = try await loaded([row(deckA, state: .failed)], then: [
            (409, Data(#"{"code":"writeBackDisabled","error":"disabled"}"#.utf8)),
            (200, statusData([refreshed])),
        ])
        await model.retryWriteBack(deckA)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "GET"])
        #expect(requests[1].url?.path == "\(base)/write-back/retry")
        #expect(requests[2].url?.path == "/api/v1/arkham/arkhamdb/status")
        #expect(model.writeBackStatus(for: deckA) == refreshed)
        #expect(model.message == arkhamDBLocalized("writeBack.error.disabled"))
        #expect(!model.needsRelinking)
    }

    @Test("An unreadable save-as-new response refreshes status and saved decks")
    func refreshAfterUnreadableSaveAsNew() async throws {
        var refreshes = 0
        let applied = row(deckA, state: .pending)
        let (model, transport) = try await loaded(
            [row(deckA, state: .conflict, reason: .remoteChanged)],
            then: [(200, Data("not json".utf8)), (200, statusData([applied]))],
            savedDecksChanged: { refreshes += 1 }
        )
        model.openConflict(deckA)
        await model.chooseResolution(.saveAsNew, for: deckA)
        await model.confirmPendingResolution()
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "POST", "GET"])
        #expect(model.writeBackStatus(for: deckA) == applied)
        #expect(model.message == DeckServiceError.malformedPayload.message)
        #expect(refreshes == 1)
        #expect(model.resolvingDeckID == deckA)
    }

    @Test("A confirmation-required error gets its own message, never the generic failure")
    func confirmationRequiredMessage() async {
        let model = model(ArkhamDBScriptedTransport([]))
        await model.perform { _ in
            throw ArkhamDBResolveConflictRequest.ValidationError.confirmationRequired
        }
        #expect(model.message == arkhamDBLocalized("writeBack.error.confirmationRequired"))
        #expect(model.message != arkhamDBLocalized("failed"))
    }

    @Test("Session expiry is not followed by a status refresh")
    func noRefreshAfterSessionExpiry() async throws {
        let (model, transport) = try await loaded(
            [row(deckA)], then: [(401, Data()), (200, statusData([]))]
        )
        await model.setWriteBack(deckA, enabled: false)
        #expect(await transport.requests.count == 2)
        #expect(model.writeBackStatus(for: deckA) == row(deckA))
    }

    @Test("Without arkhamdb.write-back.v1 no write-back row or request exists")
    func capabilityGate() async throws {
        let transport = try ArkhamDBScriptedTransport([
            (200, statusData([row(deckA, state: .conflict, reason: .remoteChanged)])),
        ])
        let model = model(transport, supportsWriteBack: false)
        await model.refreshStatus()
        #expect(model.status?.deckLinks.count == 1)
        #expect(model.writeBackStatus(for: deckA) == nil)
        #expect(model.writeBackStatuses.isEmpty)
        await model.setWriteBack(deckA, enabled: false)
        await model.chooseResolution(.keepRemote, for: deckA)
        model.openConflict(deckA)
        #expect(model.resolvingDeckID == nil)
        #expect(await transport.requests.count == 1)
    }
}

@Suite("ArkhamDB write-back app gate")
@MainActor
struct ArkhamDBWriteBackAppGateTests {
    @Test("The app only enables write-back UI with linking plus its own capability")
    func appModelGate() async {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(tokens: [ServerProfile.hosted.id: "app-token"]),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(capabilities: []))),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: ScriptedGameLifecycleService(),
            deckService: ScriptedDeckService(),
            arkhamDBService: ArkhamDBService(transport: ArkhamDBScriptedTransport([])),
            deckSyncTracker: RecordingDeckSyncTracker()
        )
        await model.flowTask?.value
        let linking = ServerCompatibility.arkhamDBAccountLinkingCapability
        let writeBack = ServerCompatibility.arkhamDBWriteBackCapability
        let cases: [(Set<String>, Bool)] = [
            ([linking, writeBack], true), ([linking], false), ([writeBack], false), ([], false),
        ]
        for (capabilities, expected) in cases {
            model.sessionState = .signedIn(
                profile: .hosted, compatibility: .modern(capabilities: capabilities),
                user: .sample
            )
            #expect(model.supportsArkhamDBWriteBack(on: .hosted) == expected)
        }
        model.sessionState = .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        #expect(!model.supportsArkhamDBWriteBack(on: .hosted))
    }
}
