@testable import ArkhamHorrorShared
import Testing

/// Continuation of ``BoardProjectionEdgeCaseTests``, split into a second file purely to
/// stay under SwiftLint's type-body-length budget: safe display-name fallback and the
/// investigator-to-location reverse lookup.
@Suite("BoardProjection — edge cases (display names / location lookup)")
struct BoardProjectionEdgeCaseTests2 {
    // MARK: - Invalid/missing human-readable names

    @Test("A blank location label falls back to its card code rather than an empty string")
    func blankLocationLabelFallsBackToCardCode() {
        let id = BoardTestFixtures.locationID("000000000104")
        let location = BoardTestFixtures.ordinaryLocation(
            id: id, cardCode: BoardTestFixtures.cardCode("c77777"), label: "   "
        )
        let snapshot = BoardTestFixtures.snapshot(locations: [(id, .ordinary(location))])
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.locations[0].displayLabel == "c77777")
    }

    @Test("A blank investigator title falls back to its card code rather than an empty string")
    func blankInvestigatorTitleFallsBackToCardCode() {
        let investigatorID = BoardTestFixtures.investigatorID("c88888")
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID, name: CardName(title: "  ", subtitle: nil)
        )
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [investigatorID: investigator],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.investigators[0].displayName == "c88888")
    }

    // MARK: - Investigator location reverse-lookup

    @Test("An investigator's currentLocationID resolves via a single reverse-lookup pass")
    func investigatorLocationResolvesViaReverseLookup() {
        let locationID = BoardTestFixtures.locationID("000000000105")
        let investigatorID = BoardTestFixtures.investigatorID("c90006")
        let location = BoardTestFixtures.ordinaryLocation(
            id: locationID, investigators: [investigatorID]
        )
        let investigator = BoardTestFixtures.investigator(id: investigatorID)
        let snapshot = BoardTestFixtures.snapshot(
            locations: [(locationID, .ordinary(location))],
            investigators: [investigatorID: investigator],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.investigators[0].currentLocationID == locationID)
    }

    @Test("An investigator absent from every location's roster projects a nil currentLocationID")
    func investigatorNotAtAnyLocationProjectsNil() {
        let investigatorID = BoardTestFixtures.investigatorID("c90007")
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [investigatorID: BoardTestFixtures.investigator(id: investigatorID)],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.investigators[0].currentLocationID == nil)
    }
}
