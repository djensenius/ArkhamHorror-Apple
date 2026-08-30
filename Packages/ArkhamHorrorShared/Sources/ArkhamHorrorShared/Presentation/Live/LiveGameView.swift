import SwiftUI

/// The native, read-only live-game screen: subscribes to `gameID`'s live session
/// (``AppModel/subscribeToLiveGame(_:)``) for as long as this screen is visible and
/// its scene is not backgrounded (``LiveGameSubscriptionPolicy`` deliberately keeps
/// a subscription through `.inactive` too -- only an actually invisible view or an
/// actually `.background`-phased scene withdraws it; see that policy's own
/// documentation for why), and renders every ``LiveGameState`` case with an explicit,
/// accessible presentation -- loading, the live ``BoardView``, a non-blocking
/// reconnecting banner over the last known board, and dedicated
/// offline/incompatible-payload/authentication-expired/terminal-failure states with
/// a Retry action for the two states retrying could actually help
/// (``LiveGameState/offline(lastKnown:)``, ``LiveGameState/terminalFailure(_:lastKnown:)``)
/// or a Dismiss action for the two
/// it cannot (authentication expiry requires signing in again rather than merely
/// retrying the same rejected token; an incompatible payload is a genuine contract
/// mismatch reconnecting cannot fix) -- never a success-shaped fallback, and never a
/// Retry action offered where ``LiveGameState/isRetryable`` reports `false`.
///
/// ## Subscription ownership
///
/// Holds exactly one ``LiveGameSubscriptionToken`` for as long as
/// ``LiveGameSubscriptionPolicy/shouldBeSubscribed(isViewVisible:scenePhase:)``
/// reports `true` for this screen's own `isViewVisible`/`scenePhase` -- driven by
/// `onAppear`/`onDisappear` and `scenePhase` changes, never by directly cancelling
/// `AppModel`'s live session itself (that reference-counted teardown decision
/// belongs entirely to ``AppModel/unsubscribeFromLiveGame(_:)``; see its
/// documentation for why this makes multiple simultaneous scenes viewing the same
/// game safe).
struct LiveGameView: View {
    let model: AppModel
    let gameID: GameID

    @State private var subscriptionToken: LiveGameSubscriptionToken?
    @State private var isViewVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var state: LiveGameState {
        model.liveGameState(for: gameID)
    }

    var body: some View {
        content
            .navigationTitle("Game")
        #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onAppear {
                isViewVisible = true
                syncSubscription()
            }
            .onDisappear {
                isViewVisible = false
                syncSubscription()
            }
            .onChange(of: scenePhase) { _, _ in
                syncSubscription()
            }
    }

    private func syncSubscription() {
        let shouldBeSubscribed = LiveGameSubscriptionPolicy.shouldBeSubscribed(
            isViewVisible: isViewVisible, scenePhase: scenePhase
        )
        switch (shouldBeSubscribed, subscriptionToken) {
        case (true, .none):
            subscriptionToken = model.subscribeToLiveGame(gameID)
        case let (false, .some(token)):
            model.unsubscribeFromLiveGame(token)
            subscriptionToken = nil
        case (true, .some), (false, .none):
            break
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            ProgressView("Loading game…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(AccountAccessibilityID.liveGameLoadingText)
        case let .live(projection):
            BoardView(projection: projection)
        case let .reconnecting(lastKnown):
            reconnectingContent(lastKnown: lastKnown)
        case .offline:
            retryableFailureContent(
                title: "Connection Lost",
                systemImage: "wifi.slash",
                message: "Unable to reach the server. Check your connection and try again.",
                accessibilityID: AccountAccessibilityID.liveGameOfflineText
            )
        case .incompatiblePayload:
            // Deliberately a Dismiss action, never `retryableFailureContent`'s Retry:
            // this is a genuine contract mismatch (see
            // ``LiveGameState/incompatiblePayload(lastKnown:)``'s own documentation)
            // that reconnecting/refetching cannot fix, so retrying would only
            // reproduce the same failure -- matching ``LiveGameState/isRetryable``,
            // which excludes this case for the same reason.
            dismissibleFailureContent(
                title: "Update Required",
                systemImage: "arrow.triangle.2.circlepath.circle",
                message: "This game's data isn't compatible with this app version. "
                    + "Update the app to continue.",
                accessibilityID: AccountAccessibilityID.liveGameIncompatiblePayloadText
            )
        case .authenticationExpired:
            dismissibleFailureContent(
                title: "Sign-In Required",
                systemImage: "person.crop.circle.badge.exclamationmark",
                message: "Your session has expired. Sign in again to continue.",
                accessibilityID: AccountAccessibilityID.liveGameAuthenticationExpiredText
            )
        case let .terminalFailure(error, _):
            retryableFailureContent(
                title: "Couldn't Load Game",
                systemImage: "exclamationmark.triangle",
                message: error.message,
                accessibilityID: AccountAccessibilityID.liveGameTerminalFailureText
            )
        }
    }

    /// A transient, non-blocking reconnecting banner over the last known board (or,
    /// if this session has never yet gone live at all, a loading indicator) -- the
    /// board never disappears merely because the socket briefly dropped, since
    /// automatic backoff-and-retry is already in progress with no action required.
    private func reconnectingContent(lastKnown: BoardProjection?) -> some View {
        ZStack(alignment: .top) {
            if let lastKnown {
                BoardView(projection: lastKnown)
            } else {
                ProgressView("Loading game…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(AccountAccessibilityID.liveGameLoadingText)
            }
            Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .accessibilityIdentifier(AccountAccessibilityID.liveGameReconnectingText)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// A retryable failure state: a full ``ContentUnavailableView`` -- deliberately
    /// never the last known board (unlike ``reconnectingContent(lastKnown:)``) --
    /// since each of these states means automatic recovery has already given up;
    /// presenting the stale board here would suggest it is still live rather than
    /// clearly communicating that it is not. Always exposes an accessible, explicit
    /// Retry action wired to ``AppModel/retryLiveGame(_:)``. Only used for states
    /// ``LiveGameState/isRetryable`` reports `true` for (see
    /// ``dismissibleFailureContent(title:systemImage:message:accessibilityID:)`` for
    /// the non-retryable counterpart).
    private func retryableFailureContent(
        title: String,
        systemImage: String,
        message: String,
        accessibilityID: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { model.retryLiveGame(gameID) }
                .accessibilityIdentifier(AccountAccessibilityID.liveGameRetryButton)
        }
        .accessibilityIdentifier(accessibilityID)
    }

    /// A non-retryable failure state: the same full-screen
    /// ``ContentUnavailableView`` presentation as
    /// ``retryableFailureContent(title:systemImage:message:accessibilityID:)``, but
    /// with a Dismiss action instead of Retry -- for states where retrying could
    /// not possibly change the outcome (``LiveGameState/authenticationExpired``
    /// requires signing in again; ``LiveGameState/incompatiblePayload(lastKnown:)``
    /// is a genuine contract mismatch reconnecting cannot fix), matching
    /// ``LiveGameState/isRetryable`` reporting `false` for both.
    private func dismissibleFailureContent(
        title: String,
        systemImage: String,
        message: String,
        accessibilityID: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Dismiss") { dismiss() }
                .accessibilityIdentifier(AccountAccessibilityID.liveGameDismissButton)
        }
        .accessibilityIdentifier(accessibilityID)
    }
}
