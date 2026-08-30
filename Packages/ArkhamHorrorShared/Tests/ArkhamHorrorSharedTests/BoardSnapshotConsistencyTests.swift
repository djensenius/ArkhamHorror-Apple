@testable import ArkhamHorrorShared
import Testing

/// Coverage for ``BoardTestFixtures/snapshot(...)``'s own internal-consistency guard:
/// resolving `activeInvestigatorID`/`leadInvestigatorID` to an investigator actually
/// present in `investigators` whenever the caller's value (possibly just its default)
/// does not already name one, so a test helper misuse can never silently build a snapshot
/// state the real contract fixtures would never emit.
@Suite("BoardTestFixtures.snapshot — internal consistency")
struct BoardSnapshotConsistencyTests {
    @Test(
        """
        Passing investigators without overriding activeInvestigatorID/leadInvestigatorID \
        resolves both to an investigator that actually exists in the map
        """
    )
    func unspecifiedActiveAndLeadResolveToAnExistingInvestigator() {
        let investigatorID = BoardTestFixtures.investigatorID("c77001")
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [investigatorID: BoardTestFixtures.investigator(id: investigatorID)]
        )
        #expect(snapshot.activeInvestigatorID == investigatorID)
        #expect(snapshot.leadInvestigatorID == investigatorID)
        #expect(snapshot.investigators[snapshot.activeInvestigatorID] != nil)
        #expect(snapshot.investigators[snapshot.leadInvestigatorID] != nil)
    }

    @Test("An explicitly-matching activeInvestigatorID/leadInvestigatorID is left unchanged")
    func explicitlyMatchingActiveAndLeadAreUnchanged() {
        let investigatorID = BoardTestFixtures.investigatorID("c77002")
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [investigatorID: BoardTestFixtures.investigator(id: investigatorID)],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        #expect(snapshot.activeInvestigatorID == investigatorID)
        #expect(snapshot.leadInvestigatorID == investigatorID)
    }

    @Test("An empty investigators map leaves the caller-supplied IDs untouched")
    func emptyInvestigatorsLeavesSuppliedIDsUntouched() {
        let placeholderID = BoardTestFixtures.investigatorID("c77003")
        let snapshot = BoardTestFixtures.snapshot(
            activeInvestigatorID: placeholderID, leadInvestigatorID: placeholderID
        )
        #expect(snapshot.investigators.isEmpty)
        #expect(snapshot.activeInvestigatorID == placeholderID)
        #expect(snapshot.leadInvestigatorID == placeholderID)
    }
}
