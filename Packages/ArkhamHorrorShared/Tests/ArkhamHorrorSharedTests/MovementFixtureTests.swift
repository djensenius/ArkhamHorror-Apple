@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused governed-fixture coverage for `Movement`'s object/null field and the closed
/// `MovementMeans`/`Destination` tag unions.
@Suite("Movement fixture decode")
struct MovementFixtureTests {
    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test("A present Movement object decodes its destination/means exactly")
    func presentMovementDecodes() throws {
        let movement = try ContractJSON.decode(Movement.self, from: fixtureData(named: "movement"))
        #expect(movement.moveMeans == .direct)
        #expect(
            try movement.moveDestination
                == .toLocation(
                    LocationID(#require(UUID(uuidString: "00000000-0000-0000-0000-00000000003d")))
                )
        )
        #expect(movement.moveAdditionalEnterCosts.tag == "Free")
        #expect(movement.moveCancelable)
        #expect(movement.moveFromInPlay)
    }

    @Test("An investigator with a null movement decodes to nil, not a spurious case")
    func nullMovementDecodesToNil() throws {
        let getGameData = try fixtureData(named: "get-game")
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: getGameData)
        let investigatorID = try InvestigatorID(CardCode("c01001"))
        let investigator = try #require(envelope.game.investigators[investigatorID])
        #expect(investigator.movement == nil)
    }

    @Test("An unrecognized MovementMeans tag decodes losslessly as .unknown")
    func unknownMovementMeansTagPreservesRawObject() throws {
        let bytes = Data(#"{"tag": "FutureMeans", "contents": {"x": 1}}"#.utf8)
        let means = try ContractJSON.decode(MovementMeans.self, from: bytes)
        guard case let .unknown(tag, rawObject) = means else {
            Issue.record("Expected .unknown")
            return
        }
        #expect(tag == "FutureMeans")
        guard case let .object(fields) = rawObject, case let .object(contents)? = fields["contents"]
        else {
            Issue.record("Expected the raw object to preserve nested contents")
            return
        }
        #expect(contents["x"]?.kindDescription == "number")
    }

    @Test("Encoding an .unknown MovementMeans throws rather than fabricating a tag")
    func encodingUnknownMovementMeansThrows() throws {
        let unknown = MovementMeans.unknown(tag: "FutureMeans", rawObject: .null)
        #expect(throws: MovementMeansError.cannotEncodeUnknownTag("FutureMeans")) {
            _ = try ContractJSON.encode(unknown)
        }
    }

    @Test("A nullary MovementMeans tag with an illegal contents key fails to decode")
    func nullaryMeansWithContentsFails() throws {
        let bytes = Data(#"{"tag": "Direct", "contents": null}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(MovementMeans.self, from: bytes)
        }
    }
}
