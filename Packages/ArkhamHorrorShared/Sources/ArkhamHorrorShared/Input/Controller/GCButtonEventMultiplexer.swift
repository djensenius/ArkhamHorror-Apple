#if canImport(GameController)
    @preconcurrency import GameController

    /// The single process-level, main-actor owner of every real
    /// `GCControllerButtonInput.pressedChangedHandler` this app installs.
    ///
    /// `pressedChangedHandler` is a single-slot property on the button
    /// itself (an OS-owned object, shared by every wrapper that has ever
    /// bound it) — if two independently-live call sites (for example two
    /// separate ``GameControllerDiscovery`` instances, each with their own
    /// ``GCControllerSource`` wrapping the same physical `GCController`)
    /// each naively assigned their own closure to that slot, the second
    /// assignment would silently discard the first, permanently starving it
    /// the moment the second later tears down (even though the first was
    /// never asked to stop). Routing every installation through this single
    /// shared multiplexer instead means the real slot is only ever assigned
    /// *once* — a closure that calls ``EventFanoutMultiplexer/fanOut(_:forKey:)`` —
    /// and any number of independent subscribers can come and go afterward
    /// without ever touching each other's registrations.
    @MainActor
    final class GCButtonEventMultiplexer {
        static let shared = GCButtonEventMultiplexer()

        typealias Token = EventFanoutMultiplexer<ObjectIdentifier, InputPhase>.Token

        private var multiplexer = EventFanoutMultiplexer<ObjectIdentifier, InputPhase>()

        private init() {}

        /// Subscribes `handler` to every future press/release of `button`,
        /// installing the real `pressedChangedHandler` on first subscribe
        /// (never overwriting any prior assignment — there never is one,
        /// since every installation in this app goes through this type) and
        /// leaving it installed for as long as any subscriber remains.
        func subscribe(
            to button: GCControllerButtonInput, handler: @escaping (InputPhase) -> Void
        ) -> Token {
            let key = ObjectIdentifier(button)
            let (token, isFirstSubscriber) = multiplexer.subscribe(forKey: key, handler: handler)
            if isFirstSubscriber {
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in
                        self?.multiplexer.fanOut(pressed ? .press : .release, forKey: key)
                    }
                }
            }
            return token
        }

        /// Unsubscribes a previously-returned token. Safe to call at most
        /// once per token (a repeat or stale-token call is a harmless
        /// no-op). Clears the real `pressedChangedHandler` only once
        /// nothing else remains subscribed to `button`, never before.
        func unsubscribe(_ token: Token, from button: GCControllerButtonInput) {
            let isNowEmpty = multiplexer.unsubscribe(token)
            if isNowEmpty {
                button.pressedChangedHandler = nil
            }
        }
    }
#endif
