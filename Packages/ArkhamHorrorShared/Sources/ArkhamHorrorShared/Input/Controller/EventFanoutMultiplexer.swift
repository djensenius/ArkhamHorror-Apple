/// A pure, hardware-independent event fan-out multiplexer: many independent
/// subscribers can each receive every event delivered ``fanOut(_:forKey:)``
/// for a given `Key`, without any subscriber's registration overwriting
/// another's.
///
/// This exists because a single real, OS-owned callback slot (for example
/// `GCControllerButtonInput.pressedChangedHandler` — see
/// ``GCButtonEventMultiplexer``, the concrete GameController-specific
/// consumer of this type) can only ever hold *one* closure at a time: if two
/// independent owners each naively assign their own closure to that slot,
/// the second assignment silently discards the first, permanently starving
/// it even after the second owner later tears down. This type is the fix —
/// every real slot installs, at most, a single closure that simply calls
/// ``fanOut(_:forKey:)``, and this type itself owns fanning that one
/// delivery out to however many subscribers are currently registered for
/// that key.
///
/// Generic and free of any GameController (or other hardware) dependency, so
/// it is fully unit-testable with fake keys/events. Subscriber identity is a
/// monotonically increasing ``Token``, never an `ObjectIdentifier` of some
/// caller-owned object — this makes stale-token handling trivially safe
/// (a token can never collide with a token from an unrelated, later
/// subscription, unlike an `ObjectIdentifier`, which can be reused once its
/// original object is deallocated).
///
/// Not `Sendable`/actor-isolated itself: every real usage in this codebase
/// (``GCButtonEventMultiplexer``) confines a single instance to the main
/// actor, matching ``ControllerInputSource``'s own main-actor-only contract.
struct EventFanoutMultiplexer<Key: Hashable, Event> {
    /// Identifies one subscription. Never reused: `nextToken` only ever
    /// increases, so a token from an already-unsubscribed (or otherwise
    /// stale) subscription can never be confused with a token minted for an
    /// unrelated, later subscription on the same or a different key.
    struct Token: Hashable {
        fileprivate let rawValue: Int
    }

    private struct Subscription {
        let key: Key
        var isEnabled: Bool
        let handler: (Event) -> Void
    }

    private var subscriptions: [Token: Subscription] = [:]
    private var tokensByKey: [Key: [Token]] = [:]
    private var nextToken = 0

    /// Registers `handler` to receive every future ``fanOut(_:forKey:)`` call
    /// for `key`, until a matching ``unsubscribe(_:)``.
    ///
    /// - Returns: the new subscription's token, and whether this was the
    ///   *first* live subscriber for `key` — callers use that to know when
    ///   they must install the one real, underlying callback (for
    ///   ``GCButtonEventMultiplexer``, `pressedChangedHandler` itself) that
    ///   ultimately drives ``fanOut(_:forKey:)``.
    mutating func subscribe(
        forKey key: Key, handler: @escaping (Event) -> Void
    ) -> (token: Token, isFirstSubscriber: Bool) {
        let token = Token(rawValue: nextToken)
        nextToken += 1
        subscriptions[token] = Subscription(key: key, isEnabled: true, handler: handler)
        let wasEmpty = (tokensByKey[key]?.isEmpty ?? true)
        tokensByKey[key, default: []].append(token)
        return (token, wasEmpty)
    }

    /// Removes a previously-registered subscription. Safe to call at most
    /// once per token; calling it again (or with a token that was never
    /// registered, or already removed) is a harmless no-op returning
    /// `isNowEmpty: false`.
    ///
    /// - Returns: whether `key` has zero remaining subscribers after this
    ///   call — callers use that to know when they must clear the one real,
    ///   underlying callback, since nothing remains to deliver it to.
    @discardableResult
    mutating func unsubscribe(_ token: Token) -> Bool {
        guard let subscription = subscriptions.removeValue(forKey: token) else {
            return false
        }
        tokensByKey[subscription.key]?.removeAll { $0 == token }
        let isNowEmpty = tokensByKey[subscription.key]?.isEmpty ?? true
        if isNowEmpty {
            tokensByKey[subscription.key] = nil
        }
        return isNowEmpty
    }

    /// Gates whether `token`'s subscription currently receives events,
    /// without removing its registration (unlike ``unsubscribe(_:)``, this
    /// never changes which key is considered "empty"). Safe to call on a
    /// stale/already-unsubscribed token — a harmless no-op.
    mutating func setEnabled(_ isEnabled: Bool, for token: Token) {
        subscriptions[token]?.isEnabled = isEnabled
    }

    /// Delivers `event` to every currently-enabled subscriber registered for
    /// `key`, in subscription order. A subscriber disabled via
    /// ``setEnabled(_:for:)`` is skipped without being unsubscribed.
    func fanOut(_ event: Event, forKey key: Key) {
        guard let tokens = tokensByKey[key] else { return }
        for token in tokens {
            guard let subscription = subscriptions[token], subscription.isEnabled else { continue }
            subscription.handler(event)
        }
    }

    /// The total number of live subscriptions across every key. Exists so
    /// tests can assert no subscriber is ever leaked once every owner has
    /// unsubscribed.
    var totalSubscriberCount: Int {
        subscriptions.count
    }
}
