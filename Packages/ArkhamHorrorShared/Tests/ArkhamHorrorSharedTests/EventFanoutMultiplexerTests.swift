@testable import ArkhamHorrorShared
import Testing

/// Tests for ``EventFanoutMultiplexer``, the pure, hardware-independent
/// fan-out layer behind ``GCButtonEventMultiplexer``'s single real
/// `pressedChangedHandler` slot per button. These tests use fake string
/// keys and a small fake event enum — no `GameController` dependency at
/// all — so they can exercise the exact multi-owner scenario the fix
/// addresses (two independent subscribers on the same key, in every order)
/// without needing a real, OS-vended `GCControllerButtonInput`.
@Suite("EventFanoutMultiplexer")
struct EventFanoutMultiplexerTests {
    private enum FakeEvent: Equatable {
        case press
        case release
    }

    @Test("a single subscriber receives every event fanned out for its key")
    func singleSubscriberReceivesEvents() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        var received: [FakeEvent] = []
        _ = multiplexer.subscribe(forKey: "button") { received.append($0) }

        multiplexer.fanOut(.press, forKey: "button")
        multiplexer.fanOut(.release, forKey: "button")

        #expect(received == [.press, .release])
    }

    @Test("subscribing reports isFirstSubscriber only for the very first subscriber on a key")
    func isFirstSubscriberOnlyOnFirstSubscription() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()

        let (_, firstIsFirst) = multiplexer.subscribe(forKey: "button") { _ in }
        #expect(firstIsFirst)

        let (_, secondIsFirst) = multiplexer.subscribe(forKey: "button") { _ in }
        #expect(!secondIsFirst)
    }

    @Test(
        """
        two independently-live subscribers on the same key both receive every event — \
        neither overwrites the other, reproducing the exact multi-owner scenario a second \
        live GameControllerDiscovery previously starved the first in
        """
    )
    func twoLiveSubscribersBothReceiveEveryEvent() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        var firstReceived: [FakeEvent] = []
        var secondReceived: [FakeEvent] = []

        _ = multiplexer.subscribe(forKey: "button") { firstReceived.append($0) }
        multiplexer.fanOut(.press, forKey: "button")

        // The second subscriber joins *after* the first already received an
        // event — modeling a second `GameControllerDiscovery` starting up
        // while the first is already live and working.
        _ = multiplexer.subscribe(forKey: "button") { secondReceived.append($0) }
        multiplexer.fanOut(.release, forKey: "button")

        // The first subscriber keeps receiving events even after the
        // second subscribes — its registration was never overwritten.
        #expect(firstReceived == [.press, .release])
        // The second only ever receives events fanned out after it joined.
        #expect(secondReceived == [.release])
    }

    @Test("unsubscribing one of two subscribers leaves the other unaffected, in either order")
    func unsubscribeOrderIndependence() {
        for firstToUnsubscribe in [0, 1] {
            var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
            var firstReceived: [FakeEvent] = []
            var secondReceived: [FakeEvent] = []

            let (firstToken, _) = multiplexer.subscribe(forKey: "button") {
                firstReceived.append($0)
            }
            let (secondToken, _) = multiplexer.subscribe(forKey: "button") {
                secondReceived.append($0)
            }

            let tokens = [firstToken, secondToken]
            multiplexer.unsubscribe(tokens[firstToUnsubscribe])
            multiplexer.fanOut(.press, forKey: "button")

            let survivorReceived = firstToUnsubscribe == 0 ? secondReceived : firstReceived
            let removedReceived = firstToUnsubscribe == 0 ? firstReceived : secondReceived
            #expect(survivorReceived == [.press])
            #expect(removedReceived.isEmpty)
        }
    }

    @Test("unsubscribe reports isNowEmpty only once every subscriber for that key is gone")
    func unsubscribeReportsEmptyOnlyWhenLastSubscriberLeaves() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        let (first, _) = multiplexer.subscribe(forKey: "button") { _ in }
        let (second, _) = multiplexer.subscribe(forKey: "button") { _ in }

        let firstUnsubscribeIsNowEmpty = multiplexer.unsubscribe(first)
        #expect(!firstUnsubscribeIsNowEmpty)
        let secondUnsubscribeIsNowEmpty = multiplexer.unsubscribe(second)
        #expect(secondUnsubscribeIsNowEmpty)
    }

    @Test("a stop/start-equivalent unsubscribe-then-resubscribe on the same key resumes delivery")
    func unsubscribeThenResubscribeResumes() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        var received: [FakeEvent] = []

        let (firstToken, _) = multiplexer.subscribe(forKey: "button") { received.append($0) }
        multiplexer.fanOut(.press, forKey: "button")
        multiplexer.unsubscribe(firstToken)
        multiplexer.fanOut(.release, forKey: "button")

        // Modeling reconnect: a brand new subscription on the same key.
        let (_, isFirstOnResubscribe) = multiplexer.subscribe(forKey: "button") {
            received.append($0)
        }
        #expect(isFirstOnResubscribe)
        multiplexer.fanOut(.press, forKey: "button")

        #expect(received == [.press, .press])
    }

    @Test("setEnabled(false) gates delivery without removing the subscription or affecting others")
    func setEnabledGatesDeliveryWithoutUnsubscribing() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        var firstReceived: [FakeEvent] = []
        var secondReceived: [FakeEvent] = []

        let (firstToken, _) = multiplexer.subscribe(forKey: "button") { firstReceived.append($0) }
        _ = multiplexer.subscribe(forKey: "button") { secondReceived.append($0) }

        multiplexer.setEnabled(false, for: firstToken)
        multiplexer.fanOut(.press, forKey: "button")
        #expect(firstReceived.isEmpty)
        #expect(secondReceived == [.press])

        // Re-enabling resumes delivery without needing to resubscribe.
        multiplexer.setEnabled(true, for: firstToken)
        multiplexer.fanOut(.release, forKey: "button")
        #expect(firstReceived == [.release])
        #expect(secondReceived == [.press, .release])
    }

    @Test("no subscriber is leaked once every owner unsubscribes")
    func noLeakAfterFullUnsubscribe() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        let (first, _) = multiplexer.subscribe(forKey: "a") { _ in }
        let (second, _) = multiplexer.subscribe(forKey: "b") { _ in }

        #expect(multiplexer.totalSubscriberCount == 2)
        multiplexer.unsubscribe(first)
        multiplexer.unsubscribe(second)
        #expect(multiplexer.totalSubscriberCount == 0)
    }

    @Test("a stale or never-registered token is a no-op and cannot affect other subscribers")
    func staleTokenUnsubscribeIsHarmlessNoOp() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        let (token, _) = multiplexer.subscribe(forKey: "button") { _ in }
        var laterReceived: [FakeEvent] = []

        let firstUnsubscribeIsNowEmpty = multiplexer.unsubscribe(token)
        #expect(firstUnsubscribeIsNowEmpty)
        // Unsubscribing the same (now stale) token again must not report
        // "now empty" a second time, nor disturb an unrelated later
        // subscription that happens to reuse the same key.
        let secondUnsubscribeIsNowEmpty = multiplexer.unsubscribe(token)
        #expect(!secondUnsubscribeIsNowEmpty)

        _ = multiplexer.subscribe(forKey: "button") { laterReceived.append($0) }
        multiplexer.fanOut(.press, forKey: "button")
        #expect(laterReceived == [.press])
    }

    @Test(
        """
        disconnect/reconnect-equivalent: a second independent subscriber on a fresh key is wholly \
        unaffected by an unrelated key's lifecycle
        """
    )
    func disconnectReconnectEquivalentAcrossKeysIsIsolated() {
        var multiplexer = EventFanoutMultiplexer<String, FakeEvent>()
        var firstKeyReceived: [FakeEvent] = []
        var secondKeyReceived: [FakeEvent] = []

        let (firstToken, _) = multiplexer.subscribe(forKey: "buttonA") {
            firstKeyReceived.append($0)
        }
        _ = multiplexer.subscribe(forKey: "buttonB") { secondKeyReceived.append($0) }

        multiplexer.unsubscribe(firstToken)
        multiplexer.fanOut(.press, forKey: "buttonA")
        multiplexer.fanOut(.press, forKey: "buttonB")

        #expect(firstKeyReceived.isEmpty)
        #expect(secondKeyReceived == [.press])
    }
}
