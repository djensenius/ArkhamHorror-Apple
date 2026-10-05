@testable import ArkhamHorrorShared
import Testing

extension AppModelLiveGameTests {
    @Test("REST live-game load stores multiplayer mode and LiveGameView maps solo only")
    func restEnvelopeMultiplayerModeDrivesLiveGameSoloMapping() async throws {
        try await assertRESTEnvelopeMode(.withFriends, mapsToSolo: false)
        try await assertRESTEnvelopeMode(.solo, mapsToSolo: true)
        #expect(!LiveGameMultiplayerPresentation.isSolo(nil))
        #expect(!LiveGameMultiplayerPresentation.isSolo(MultiplayerVariant("FutureMode")))
    }

    private func assertRESTEnvelopeMode(
        _ mode: MultiplayerVariant,
        mapsToSolo expectedIsSolo: Bool
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let base = try loadGetGame()
        let envelope = GetGameEnvelope(
            playerID: base.playerID,
            multiplayerMode: mode,
            game: base.game,
            eventID: base.eventID
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        #expect(model.liveGameMultiplayerModes[gameID] == mode)
        #expect(
            LiveGameMultiplayerPresentation.isSolo(model.liveGameMultiplayerModes[gameID])
                == expectedIsSolo
        )
    }
}
