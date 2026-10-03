/// Web-compatible multiplayer invite operations for ``AppModel``.
extension AppModel {
    /// Verifies and joins a web-shared pending-game invite through the same
    /// server-owned lifecycle sequence the web client uses: `GET /join` first,
    /// then `PUT /join`, followed by a games-list refresh. The returned id comes
    /// from the server's join response; a mismatched or unsupported envelope is
    /// treated as contract drift rather than guessed at locally.
    ///
    /// - Throws: ``GameLifecycleError``, or rethrows `CancellationError`.
    @discardableResult
    func joinGameFromInvite(_ id: GameID) async throws -> GameID {
        guard case let .signedIn(profile, _, _) = sessionState else {
            throw GameLifecycleError.sessionExpired
        }
        let capturedGeneration = generation
        let capturedCredentialEpoch = currentCredentialEpoch(for: profile.id)
        let capturedGlobalEpoch = currentGlobalCredentialEpoch()
        let token: String
        do {
            token = try await currentGameLifecycleToken(for: profile)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch GameLifecycleTokenAccessError.stale {
            throw CancellationError()
        } catch GameLifecycleTokenAccessError.noToken {
            throw GameLifecycleError.sessionExpired
        } catch GameLifecycleTokenAccessError.tokenStore {
            throw GameLifecycleError.tokenUnavailable
        }
        do {
            let preview = try await gameLifecycleService.peekLobby(id, on: profile, token: token)
            guard preview == .game(id) else {
                throw GameLifecycleError.malformedPayload
            }
            let joined = try await gameLifecycleService.joinGame(id, on: profile, token: token)
            guard case let .game(joinedID) = joined else {
                throw GameLifecycleError.malformedPayload
            }
            refreshGames()
            return joinedID
        } catch let error as GameLifecycleError {
            if case .sessionExpired = error, isCurrent(capturedGeneration) {
                await handleGameLifecycleSessionExpired(
                    profile: profile,
                    generation: capturedGeneration,
                    credentialEpoch: capturedCredentialEpoch,
                    globalEpoch: capturedGlobalEpoch
                )
            }
            throw error
        }
    }
}
