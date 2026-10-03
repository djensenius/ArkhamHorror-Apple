@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game invite links")
struct GameInviteTests {
    private let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!

    @Test("Raw UUIDs parse as join invites")
    func rawUUIDParsesAsJoinInvite() throws {
        let invite = try GameInvite.parse("00000000-0000-0000-0000-000000000042")
        #expect(invite == GameInvite(gameID: GameID(uuid), route: .join))
    }

    @Test("Web join and claim-seat URLs parse without depending on the host")
    func webURLsParse() throws {
        let join = try GameInvite.parse(
            "https://arkhamhorror.app/games/00000000-0000-0000-0000-000000000042/join"
        )
        #expect(join == GameInvite(gameID: GameID(uuid), route: .join))

        let claimSeat = try GameInvite.parse(
            "https://example.test/prefix/games/00000000-0000-0000-0000-000000000042/claim-seat"
        )
        #expect(claimSeat == GameInvite(gameID: GameID(uuid), route: .claimSeat))
    }

    @Test("Unsupported invite text is rejected instead of guessed at")
    func invalidInviteIsRejected() {
        #expect(throws: GameInvite.ParseError.unsupported) {
            try GameInvite.parse("https://arkhamhorror.app/not-a-game/42")
        }
    }

    @Test("Invite URL construction preserves a custom server path prefix")
    func webURLPreservesProfilePathPrefix() throws {
        let profile = try ServerProfile.custom(
            displayName: "Staging",
            rawURL: "https://example.test/arkham"
        )
        let url = try #require(GameInvite.webURL(
            for: GameID(uuid), route: .claimSeat, on: profile
        ))
        let expectedURL = "https://example.test/arkham/games/"
            + "00000000-0000-0000-0000-000000000042/claim-seat"
        #expect(url.absoluteString == expectedURL)
    }
}
