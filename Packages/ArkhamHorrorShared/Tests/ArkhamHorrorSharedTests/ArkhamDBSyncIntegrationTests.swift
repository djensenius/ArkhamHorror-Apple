@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB sync integration")
@MainActor
struct ArkhamDBSyncIntegrationTests {
    private func signedInModel(
        transport: ArkhamDBScriptedTransport, base: ScriptedDeckService
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
            deckSyncTracker: RecordingDeckSyncTracker()
        )
        await model.flowTask?.value
        return model
    }

    @Test("Only the negotiated capability selects the linked sync route and account surface")
    func syncCapabilityGate() async {
        let base = ScriptedDeckService()
        let model = await signedInModel(transport: ArkhamDBScriptedTransport([]), base: base)
        #expect(model.supportsArkhamDB(on: .hosted))
        #expect(model.deckService(on: .hosted) is ArkhamDBSyncDeckService)
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        #expect(!model.supportsArkhamDB(on: .hosted))
        #expect(model.deckService(on: .hosted) is ScriptedDeckService)
        model.sessionState = .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        #expect(!model.supportsArkhamDB(on: .hosted))
        #expect(model.deckService(on: .hosted) is ScriptedDeckService)
    }

    @Test("Refresh-and-sync and automatic before-choice sync both use the linked server route")
    func manualAndAutomaticSync() async throws {
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("syncedDeck")), (200, arkhamDBFixtureData("syncedDeck")),
        ])
        let base = ScriptedDeckService()
        await base.enqueueList(.success([deck]))
        await base.enqueueValidate(.success(DeckValidationSuccess()))
        let model = await signedInModel(transport: transport, base: base)
        let context = try await model.currentDeckRequestContext(for: .hosted)
        let decks = DecksViewModel(
            profile: .hosted, deckService: model.deckService(on: .hosted),
            tokenProvider: { context }
        )
        await decks.refreshAndSync()
        #expect(decks.syncState(for: deck) == .succeeded(deckSyncSuccessMessage()))
        let result = try await model.syncDeckBeforeChoiceIfNeeded(
            deck,
            profile: .hosted,
            context: context
        )
        #expect(result.deck == deck)
        #expect(result.didAttemptSync)
        #expect(result.note == deckSyncSuccessMessage())
        #expect(await base.syncedIDs.isEmpty)
        let paths = await transport.requests.compactMap { $0.url?.path }
        #expect(paths == Array(
            repeating: "/api/v1/arkham/arkhamdb/decks/00000000-0000-0000-0000-000000000017/sync",
            count: 2
        ))
    }

    @Test("Automatic sync's 409 keeps the saved deck and gives a relink note, not sign-out")
    func automaticSyncRelinkNote() async throws {
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try ArkhamDBScriptedTransport([(
            409,
            arkhamDBFixtureData("tokenExpiredError")
        )])
        let base = ScriptedDeckService()
        await base.enqueueValidate(.success(DeckValidationSuccess()))
        let model = await signedInModel(transport: transport, base: base)
        let context = try await model.currentDeckRequestContext(for: .hosted)
        let result = try await model.syncDeckBeforeChoiceIfNeeded(
            deck,
            profile: .hosted,
            context: context
        )
        #expect(result.deck == deck)
        #expect(result.note == arkhamDBLocalized("relinkRequired"))
        #expect(model
            .deckChoiceSyncNote(for: deck.id, on: .hosted) == arkhamDBLocalized("relinkRequired"))
        guard case .signedIn = model.sessionState else {
            Issue.record("ArkhamDB token expiry must not sign the app out")
            return
        }
        #expect(await transport.requests.count == 1)
    }
}
