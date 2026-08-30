#if canImport(SwiftUI)
    import SwiftUI

    /// Whether a live-game screen should currently hold a subscription to its game's
    /// live session, derived purely from view visibility and scene phase.
    ///
    /// Pure and side-effect-free: no view, task, or `AppModel` dependency, so the
    /// visibility/scene-phase-to-subscription mapping is directly unit-testable
    /// without any SwiftUI hosting -- mirroring this package's existing pure-policy
    /// pattern (`BoardAnimationPolicy`/`BoardLayoutDecision` in `BoardView.swift`).
    ///
    /// Background/foreground is handled by treating a backgrounded scene exactly
    /// like a disappeared view: both simply withdraw this screen's subscription.
    /// Because ``AppModel/subscribeToLiveGame(_:)`` is reference-counted per game
    /// (see that method's documentation), a *different* scene showing the same game
    /// keeps that game's session alive even while this scene is backgrounded, and
    /// backgrounding never cancels a game no other visible scene is watching's
    /// session a moment sooner than an ordinary "last viewer disappeared" teardown
    /// would anyway.
    ///
    /// `.inactive` is deliberately treated exactly like `.active` (i.e. a visible
    /// view stays subscribed): `.inactive` covers a window merely losing key focus
    /// while still fully visible -- macOS focus handoff between two windows, iPadOS
    /// Split View/Slide Over/Stage Manager, Control Center, or any other transient,
    /// non-backgrounded interruption. Requiring `.active` here previously withdrew
    /// the subscription on every such focus toggle, and the *last* viewer doing so
    /// tore the shared session down entirely -- turning an ordinary window-focus
    /// change into a full state wipe and an expensive REST-refetch/socket-reconnect
    /// storm, and risking a two-window focus handoff briefly emptying a shared
    /// game's subscriber set. Only an actually invisible view or an actually
    /// `.background`-phased scene withdraws a subscription.
    enum LiveGameSubscriptionPolicy {
        /// Whether a subscription should be held right now.
        ///
        /// `scenePhase` is read defensively even though a truly backgrounded scene
        /// also stops delivering `onAppear`/`onDisappear`/task work in practice: this
        /// keeps the policy correct (and directly testable) independent of exactly
        /// when SwiftUI happens to deliver those callbacks relative to a phase
        /// transition.
        static func shouldBeSubscribed(isViewVisible: Bool, scenePhase: ScenePhase) -> Bool {
            isViewVisible && scenePhase != .background
        }
    }
#endif
