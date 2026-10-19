@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension AppModelCampaignPromptTests {
    @Test(
        "Campaign saved-deck sync expiry signs out without PUT or submission",
        .timeLimit(.minutes(1))
    )
    func campaignSavedDeckSessionExpiryDuringSyncAborts() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(gameService: service, deckService: deckService)
        let gameID = GameID(UUID())
        let ownerID = PlayerID(UUID())
        let connection = FakeGameSocketConnection()
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID,
                mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let deck = try deckSyncChoiceSampleDeck()
        await deckService.enqueueSync(.failure(DeckServiceError.sessionExpired))
        await service.enqueueChooseDeckResult(.success(()))
        await connection.enqueueSendResult(.success(()))

        _ = await model.upgradeCampaignDeck(
            using: deck,
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(await deckService.callOrder == ["syncDeck"])
        #expect(await service.lastChooseDeckRequest == nil)
        #expect(await connection.sentData.isEmpty)
        guard case let .signedOut(profile, compatibility) = model.sessionState,
              profile == .hosted,
              case .modern = compatibility
        else {
            Issue.record("Expected hosted modern signed-out session after sync 401")
            return
        }
    }
}
