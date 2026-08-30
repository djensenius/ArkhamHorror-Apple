@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `GameLifecycleServiceTests.swift` purely by struct-body length:
/// path-segment percent-encoding safety coverage for
/// ``GameLifecycleService/percentEncodedGameIDSegment(_:)`` (audited against slash,
/// dot-segment, percent, query/fragment, and Unicode injection).
@Suite("GameLifecycleService — path-segment safety")
struct GameLifecycleServicePathSegmentTests {
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)

    @Test(
        """
        A game-ID path segment percent-encodes to unreserved characters only, closing \
        slash/percent/dot/query/fragment/Unicode injection
        """,
        arguments: [
            ("../../etc/passwd", "%2E%2E%2F%2E%2E%2Fetc%2Fpasswd"),
            ("a/b", "a%2Fb"),
            ("..", "%2E%2E"),
            (".", "%2E"),
            ("a%2Fb", "a%252Fb"),
            ("a?b=1", "a%3Fb%3D1"),
            ("a#frag", "a%23frag"),
            ("héllo", "h%C3%A9llo"),
        ]
    )
    func pathSegmentEncodingClosesInjection(raw: String, expectedEncoded: String) throws {
        let encoded = try #require(GameLifecycleService.percentEncodedGameIDSegment(raw))
        #expect(encoded == expectedEncoded)
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("?"))
        #expect(!encoded.contains("#"))
    }

    @Test("A real GameID (always a UUID) requires no escaping and round-trips unchanged")
    func realGameIDRequiresNoEscaping() throws {
        let encoded = try #require(
            GameLifecycleService.percentEncodedGameIDSegment(gameID.description)
        )
        #expect(encoded == gameID.description)
    }
}
