@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invite token review fixes")
struct AppModelGameInviteTokenReviewTests {
    private struct TokenReadFakes {
        let model: AppModel
        let tokenStore: FakeTokenStore
        let service: ScriptedGameLifecycleService
    }

    private func makeTokenReadModel() async -> TokenReadFakes {
        let service = ScriptedGameLifecycleService()
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "session-token"])
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        await tokenStore.setTokenReadGated(true)
        return TokenReadFakes(model: model, tokenStore: tokenStore, service: service)
    }

    private func invite(for model: AppModel, seat: CardCode) -> ClaimSeatInviteDetails {
        ClaimSeatInviteDetails(
            gameID: GameID(UUID()),
            seats: [seat],
            playerCount: 2,
            viewerHasSeat: false,
            sessionToken: GameInviteSessionToken(
                profileID: ServerProfile.hosted.id,
                generation: model.generation,
                credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                globalEpoch: model.currentGlobalCredentialEpoch()
            )
        )
    }

    @Test("claim-seat invite routes a current missing token through session expiry")
    func claimSeatInviteHandlesCurrentMissingTokenRead() async throws {
        let fakes = await makeTokenReadModel()
        let seat = try CardCode("c01001")
        let invite = invite(for: fakes.model, seat: seat)

        let claimTask = Task { try await fakes.model.claimSeatFromInvite(seat, using: invite) }
        await fakes.tokenStore.waitUntilTokenReadPending(1)
        await fakes.tokenStore.resumeOldestTokenRead(with: .success(nil))

        await #expect(throws: CancellationError.self) {
            _ = try await claimTask.value
        }
        #expect(fakes.model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await fakes.service.callOrder == [])
    }

    @Test("claim-seat invite revalidates before surfacing a token-store read failure")
    func claimSeatInviteRejectsSessionChangeBeforeTokenReadFailure() async throws {
        let fakes = await makeTokenReadModel()
        let seat = try CardCode("c01001")
        let invite = invite(for: fakes.model, seat: seat)

        let claimTask = Task { try await fakes.model.claimSeatFromInvite(seat, using: invite) }
        await fakes.tokenStore.waitUntilTokenReadPending(1)
        fakes.model.generation += 1
        await fakes.tokenStore.resumeOldestTokenRead(with: .failure(TestFailure()))

        await #expect(throws: CancellationError.self) {
            _ = try await claimTask.value
        }
        #expect(await fakes.service.callOrder == [])
    }
}
