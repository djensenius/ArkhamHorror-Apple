import SwiftUI

/// The native, read-only live-game screen: subscribes to `gameID`'s live session
/// (``AppModel/subscribeToLiveGame(_:)``) for as long as this screen is visible and
/// its scene is active, and renders every ``LiveGameState`` case with an explicit,
/// accessible presentation -- loading, the live ``BoardView``, a non-blocking
/// reconnecting banner over the last known board, and dedicated
/// offline/incompatible-payload/authentication-expired/terminal-failure states with
/// a Retry (or Dismiss, for authentication expiry, which requires signing in again
/// rather than merely retrying the same rejected token) action -- never a
/// success-shaped fallback.
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
            .onChange(of: scenePhase) {
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
                message: "Automatic reconnect attempts were unsuccessful.",
                accessibilityID: AccountAccessibilityID.liveGameOfflineText
            )
        case .incompatiblePayload:
            retryableFailureContent(
                title: "Update Required",
                systemImage: "arrow.triangle.2.circlepath.circle",
                message: "This game's data isn't compatible with this app version. "
                    + "Update the app to continue.",
                accessibilityID: AccountAccessibilityID.liveGameIncompatiblePayloadText
            )
        case .authenticationExpired:
            ContentUnavailableView {
                Label("Sign-In Required", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Your session has expired. Sign in again to continue.")
            } actions: {
                Button("Dismiss") { dismiss() }
                    .accessibilityIdentifier(AccountAccessibilityID.liveGameDismissButton)
            }
            .accessibilityIdentifier(AccountAccessibilityID.liveGameAuthenticationExpiredText)
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
    /// since each of these states means automatic recovery has already given up (or
    /// cannot succeed at all, for an incompatible payload); presenting the stale
    /// board here would suggest it is still live rather than clearly communicating
    /// that it is not. Always exposes an accessible, explicit Retry action wired to
    /// ``AppModel/retryLiveGame(_:)``.
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
}
