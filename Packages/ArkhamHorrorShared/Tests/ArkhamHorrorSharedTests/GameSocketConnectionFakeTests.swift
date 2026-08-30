@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Pins ``FakeGameSocketConnection``'s own conformance to the
/// ``GameSocketConnection`` contract it exists to stand in for, independent of any
/// AppModel session logic. A prior revision's `nextEvent()` threw
/// ``GameSocketTransportError`` once `isClosed` was set -- misrepresenting every
/// already-closed connection as an unclean transport loss instead of the clean
/// closure `close(code:reason:)` actually recorded, which the contract's own doc
/// comment (`GameSocketConnection.swift`) requires a conformance to surface as
/// ``GameSocketEvent/closed(code:reason:)``. These tests fail against that prior
/// throwing behavior and pass against the corrected one.
@Suite("FakeGameSocketConnection contract fidelity")
struct GameSocketConnectionFakeTests {
    @Test(
        """
        A nextEvent() call after close() reports the exact close code/reason as \
        .closed, never a transport error
        """
    )
    func nextEventAfterCloseReportsClosed() async throws {
        let connection = FakeGameSocketConnection()
        connection.close(code: .goingAway, reason: Data("bye".utf8))
        await connection.waitUntilClosed(count: 1)

        let event = try await connection.nextEvent()
        guard case let .closed(code, reason) = event else {
            Issue.record("Expected .closed, got \(event)")
            return
        }
        #expect(code == .goingAway)
        #expect(reason == Data("bye".utf8))
    }

    @Test("A repeated nextEvent() call after close() keeps reporting the same closed result")
    func repeatedNextEventAfterCloseIsStable() async throws {
        let connection = FakeGameSocketConnection()
        connection.close(code: .normalClosure, reason: nil)
        await connection.waitUntilClosed(count: 1)

        let first = try await connection.nextEvent()
        let second = try await connection.nextEvent()
        #expect(first == .closed(code: .normalClosure, reason: nil))
        #expect(second == .closed(code: .normalClosure, reason: nil))
    }

    @Test(
        """
        close() is idempotent: a second close() with a different code \
        cannot change the recorded closure
        """
    )
    func secondCloseCannotOverwriteTheRecordedClosure() async throws {
        let connection = FakeGameSocketConnection()
        connection.close(code: .normalClosure, reason: nil)
        await connection.waitUntilClosed(count: 1)
        connection.close(code: .goingAway, reason: Data("later".utf8))
        await connection.waitUntilClosed(count: 2)

        let event = try await connection.nextEvent()
        #expect(event == .closed(code: .normalClosure, reason: nil))
    }
}
