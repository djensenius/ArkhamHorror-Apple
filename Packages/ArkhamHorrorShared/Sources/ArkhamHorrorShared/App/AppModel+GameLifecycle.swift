import Foundation

/// A ``AppModel/currentGameLifecycleToken(for:)`` failure, distinguishing a merely
/// stale/superseded read (never surfaced as an application error, exactly like
/// ``StaleCredentialEpochError`` elsewhere) from a genuine ``TokenStore`` failure or
/// an absent token.
enum GameLifecycleTokenAccessError: Error, Sendable {
    /// The captured credential/global epoch no longer matches: a concurrent
    /// sign-out, profile-endpoint edit, or storage reset has already superseded this
    /// read. Treated identically to `CancellationError` by every caller.
    case stale
    /// Reading the token itself failed.
    case tokenStore(TokenStoreFailure)
    /// No token is currently stored for this profile, even though the caller
    /// observed `sessionState == .signedIn` moments earlier -- a concurrent
    /// sign-out/invalidation already raced this read.
    case noToken
}

/// Authenticated game-list/lobby state and operations, bound to `AppModel`'s existing
/// single session/token authority.
///
/// Every operation below:
/// - Only ever proceeds from `sessionState == .signedIn`, reading the profile fresh
///   from `sessionState` rather than caching it, so it can never target a
///   superseded profile.
/// - Reads its bearer token exclusively through
///   ``AppModel/currentGameLifecycleToken(for:)`` -- the same serialized,
///   epoch-guarded ``AppModel/serializedTokenAccess(for:epoch:globalEpoch:_:)`` path
///   every durable token mutation uses -- never a second, parallel token cache or
///   observable property.
/// - Captures ``AppModel/generation`` at the start and rechecks it
///   (``AppModel/isCurrent(_:)``) before any completion mutates state, so sign-out,
///   profile switch, or any other session-level invalidation discards a stale
///   in-flight result exactly like every other `AppModel` flow.
/// - On an explicit HTTP 401 (``GameLifecycleError/sessionExpired``), routes through
///   ``AppModel/handleGameLifecycleSessionExpired(profile:)`` -- never silently signs
///   out or leaves stale game content active.
///
/// `AppModel` is shared process-wide across every window (see ``RootView``), so every
/// property and task here is likewise process-wide: two windows observing the same
/// game/list share the identical in-flight task and its eventual result, and one
/// window's view disappearing never cancels an operation a different window is still
/// waiting on (nothing here is owned by, or cancelled from, SwiftUI view lifecycle).
extension AppModel {
    // MARK: - Token access

    /// Reads the current token for `profile` through
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)``, the same serialized,
    /// epoch-guarded path every durable token mutation uses.
    ///
    /// - Throws: ``GameLifecycleTokenAccessError``, or rethrows `CancellationError`.
    func currentGameLifecycleToken(for profile: ServerProfile) async throws -> String {
        let credentialEpoch = currentCredentialEpoch(for: profile.id)
        let globalEpoch = currentGlobalCredentialEpoch()
        let token: String?
        do {
            token = try await serializedTokenAccess(
                for: profile.id, epoch: credentialEpoch, globalEpoch: globalEpoch
            ) { [tokenStore] in
                try await tokenStore.token(for: profile.id)
            }
        } catch is StaleCredentialEpochError {
            throw GameLifecycleTokenAccessError.stale
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw GameLifecycleTokenAccessError.tokenStore(tokenStoreFailure(from: error))
        }
        guard let token else {
            throw GameLifecycleTokenAccessError.noToken
        }
        return token
    }

    // MARK: - Session-expiry / reset

    /// Reacts to a ``GameLifecycleError/sessionExpired`` (HTTP 401) observed by a
    /// game-lifecycle request that began at `generation`/`credentialEpoch`/
    /// `globalEpoch` -- the exact values its own attempt captured at the moment it
    /// started, never re-read fresh here. Deletes the now-rejected token and
    /// transitions to `.signedOut`, routing through the exact same single token
    /// authority a rejected `whoami` token restoration already uses
    /// (``deleteUnauthorizedToken(profile:compatibility:generation:credentialEpoch:globalEpoch:)``)
    /// rather than a second, parallel "am I still signed in" path.
    ///
    /// Threading the caller's own captured values through (rather than reading
    /// ``generation``/``currentCredentialEpoch(for:)``/``currentGlobalCredentialEpoch()``
    /// fresh here) is what makes this safe even when a stale request's 401 races a
    /// concurrent sign-out followed by a *newer*, successful sign-in to the very
    /// same profile: `deleteUnauthorizedToken`'s own generation/epoch recheck,
    /// performed at the last possible moment before the Keychain is touched,
    /// compares against these stale captured values -- never whatever happens to be
    /// current by the time this actually runs -- so a 401 that outlived its own
    /// request's relevance can never delete a newer, unrelated session's token.
    /// Every call site must capture its own generation/credentialEpoch/globalEpoch
    /// at the same moment it captures everything else its own staleness guard
    /// needs, and must confirm its own attempt is still current before calling this.
    ///
    /// A no-op if the session has already moved on: signed out, switched to a
    /// different profile, or a newer operation has already superseded `generation`.
    func handleGameLifecycleSessionExpired(
        profile: ServerProfile, generation: Int, credentialEpoch: Int, globalEpoch: Int
    ) async {
        guard case let .signedIn(currentProfile, compatibility, _) = sessionState,
              currentProfile == profile
        else { return }
        await deleteUnauthorizedToken(
            profile: profile,
            compatibility: compatibility,
            generation: generation,
            credentialEpoch: credentialEpoch,
            globalEpoch: globalEpoch
        )
    }

    /// Clears every game-lifecycle/lobby state property back to its initial, empty
    /// value and cancels every in-flight list/action task.
    ///
    /// Called at every point a signed-in session ends or is superseded (sign-out,
    /// profile switch/retry/in-place profile edit restart, and 401 session expiry),
    /// so stale game content for a previous profile/session is never left active.
    /// Idempotent; safe to call when already empty (for example from a flow that was
    /// never signed in).
    func resetGameLifecycleState() {
        gameListTask?.cancel()
        for task in gameLifecycleActionTasks.values {
            task.cancel()
        }
        gameListTask = nil
        gameListState = .idle
        gameLifecycleActions = [:]
        gameLifecycleActionFailures = [:]
        gameOpenSeats = [:]
        gameLifecycleActionAttempts = [:]
        gameLifecycleActionTasks = [:]
        gameListGeneration += 1
    }

    // MARK: - Games list

    /// The profile, generation, and credential/global-epoch snapshot captured when a
    /// games-list load/refresh starts, threaded through its async body. A small named
    /// type (rather than a multi-parameter/tuple signature) keeps every function
    /// below within this project's line-length and tuple-arity conventions.
    private struct GameListLoadAttempt: Sendable {
        let profile: ServerProfile
        let listGeneration: Int
        let sessionGeneration: Int
        let credentialEpoch: Int
        let globalEpoch: Int
    }

    private func isCurrentGameList(_ attempt: GameListLoadAttempt) -> Bool {
        attempt.listGeneration == gameListGeneration && isCurrent(attempt.sessionGeneration)
    }

    /// Loads (or refreshes) the authenticated games list. A no-op unless currently
    /// signed in. Supersedes and cancels any previous in-flight load/refresh.
    func refreshGames() {
        guard case let .signedIn(profile, _, _) = sessionState else { return }
        gameListTask?.cancel()
        gameListGeneration += 1
        let attempt = GameListLoadAttempt(
            profile: profile,
            listGeneration: gameListGeneration,
            sessionGeneration: generation,
            credentialEpoch: currentCredentialEpoch(for: profile.id),
            globalEpoch: currentGlobalCredentialEpoch()
        )
        gameListState = .loading(previous: gameListState.games)
        gameListTask = Task { [weak self] in
            await self?.performRefreshGames(attempt)
        }
    }

    private func performRefreshGames(_ attempt: GameListLoadAttempt) async {
        guard let token = await resolveGameListToken(attempt) else { return }

        do {
            let games = try await gameLifecycleService.listGames(on: attempt.profile, token: token)
            guard isCurrentGameList(attempt) else { return }
            gameListState = .loaded(games)
        } catch is CancellationError {
            return
        } catch let error as GameLifecycleError {
            guard isCurrentGameList(attempt) else { return }
            gameListState = .failed(error, previous: gameListState.games)
            if case .sessionExpired = error {
                await handleGameLifecycleSessionExpired(
                    profile: attempt.profile,
                    generation: attempt.sessionGeneration,
                    credentialEpoch: attempt.credentialEpoch,
                    globalEpoch: attempt.globalEpoch
                )
            }
        } catch {
            guard isCurrentGameList(attempt) else { return }
            gameListState = .failed(
                .transportFailure("Unexpected game-list failure."), previous: gameListState.games
            )
        }
    }

    /// Resolves the games list's bearer token, recording a typed failure on every
    /// non-stale failure. Returns `nil` on any failure or staleness; callers must
    /// return immediately when `nil`. Split out of ``performRefreshGames(_:)`` purely
    /// to keep that function's branching within this project's complexity convention.
    private func resolveGameListToken(_ attempt: GameListLoadAttempt) async -> String? {
        do {
            return try await currentGameLifecycleToken(for: attempt.profile)
        } catch is CancellationError {
            return nil
        } catch let tokenError as GameLifecycleTokenAccessError {
            guard isCurrentGameList(attempt) else { return nil }
            switch tokenError {
            case .stale:
                return nil
            case .noToken:
                gameListState = .failed(.sessionExpired, previous: gameListState.games)
            case .tokenStore:
                gameListState = .failed(.tokenUnavailable, previous: gameListState.games)
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Create (typed operation; no polished create UI in this slice)

    /// Creates a new game and refreshes the games list on success.
    ///
    /// Exposed for tests and a future option-driven create surface; this slice never
    /// presents a raw-ID creation form.
    ///
    /// - Throws: ``GameLifecycleError``, or rethrows `CancellationError`.
    @discardableResult
    func createGame(_ request: CreateGameRequest) async throws -> GameID {
        guard case let .signedIn(profile, _, _) = sessionState else {
            throw GameLifecycleError.sessionExpired
        }
        // Captured once, here, alongside `profile` -- not re-read fresh at the
        // catch site below -- so a 401 that arrives after this exact call has
        // already been superseded (sign-out, profile switch, or a concurrent
        // sign-in to this same profile) can never be mistaken for *that* newer
        // session's own expiry. See `handleGameLifecycleSessionExpired`.
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
            let envelope = try await gameLifecycleService.createGame(
                request, on: profile, token: token
            )
            switch envelope {
            case let .game(id):
                refreshGames()
                return id
            case .unsupported:
                throw GameLifecycleError.malformedPayload
            }
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
