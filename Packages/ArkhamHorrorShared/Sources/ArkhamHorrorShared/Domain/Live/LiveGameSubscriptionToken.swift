import Foundation

/// A live-game subscription handle returned by ``AppModel/subscribeToLiveGame(_:)``.
///
/// Opaque and `Equatable` only for identity comparison in tests; a view holds exactly
/// one of these per game it is currently showing and passes it back, unchanged, to
/// ``AppModel/unsubscribeFromLiveGame(_:)`` when it stops (or, driven by
/// ``LiveGameSubscriptionPolicy``, is temporarily backgrounded). See
/// ``AppModel/liveGameViewers`` for why multiple simultaneous subscriptions to the
/// *same* game (from independent scenes/windows) are supported and share one
/// underlying session.
struct LiveGameSubscriptionToken: Sendable, Equatable {
    let gameID: GameID
    let subscriptionID: UUID

    /// Constructs a fresh, uniquely-identified token for `gameID`. Internal (not
    /// `private`) so `@testable`-imported tests can synthesize an
    /// already-unsubscribed/mismatched token directly, without first reaching
    /// through a signed-in `AppModel`, while ordinary callers only ever receive one
    /// back from ``AppModel/subscribeToLiveGame(_:)``.
    static func issue(for gameID: GameID) -> LiveGameSubscriptionToken {
        LiveGameSubscriptionToken(gameID: gameID, subscriptionID: UUID())
    }
}
