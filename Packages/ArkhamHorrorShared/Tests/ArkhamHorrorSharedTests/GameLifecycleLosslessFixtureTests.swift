@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Lossless numeric passthrough through the *aggregate* game-lifecycle fixture path (review
/// round 3, MEDIUM #9): proves `ContractJSON`'s arbitrary-precision numeric handling holds
/// end-to-end through a real request type's decode/encode cycle, not merely in isolated
/// `JSONNumber` unit tests. `ChooseDeckRequest`'s `deckList` field is a `DeckListInput`
/// carrying an `ExternalID`-typed identifier that must survive a long integer and a
/// large-exponent value byte-for-byte. Kept as its own file (rather than inside
/// `GameLifecycleTests`) purely to stay under SwiftLint's file/type-length limits.
@Suite("GameLifecycle lossless fixture passthrough")
struct GameLifecycleLosslessFixtureTests {
    @Test("A long numeric external deck id round-trips through ContractJSON without precision loss")
    func longNumericExternalIdRoundTripsThroughContractJSON() throws {
        let longId = "123456789012345678901234567890"
        let bytes = Data(
            """
            {"investigatorId":"01001","deckUrl":null,"deckList":{"id":\(longId),\
            "investigator_code":"01001","slots":{},"sideSlots":{}}}
            """.utf8
        )
        let request = try ContractJSON.decode(ChooseDeckRequest.self, from: bytes)
        let reencoded = try ContractJSON.encode(request)
        let json = try #require(String(data: reencoded, encoding: .utf8))
        #expect(
            json.contains(longId),
            "Expected the exact long-digit id to survive re-encoding, got: \(json)"
        )
    }

    @Test("A large-exponent external deck id round-trips through ContractJSON without precision")
    func largeExponentExternalIdRoundTripsThroughContractJSON() throws {
        let bytes = Data(
            """
            {"investigatorId":"01001","deckUrl":null,"deckList":{"id":1e128,\
            "investigator_code":"01001","slots":{},"sideSlots":{}}}
            """.utf8
        )
        let request = try ContractJSON.decode(ChooseDeckRequest.self, from: bytes)
        let reencoded = try ContractJSON.encode(request)
        let json = try #require(String(data: reencoded, encoding: .utf8))
        #expect(
            json.contains("1e128") || json.contains("1E128"),
            "Expected the exact large-exponent id to survive re-encoding, got: \(json)"
        )
    }
}
