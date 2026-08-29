@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused governed-fixture coverage for `Investigator.unhealedHorrorThisRound`'s
/// intentionally unbounded (including negative) range, and its `Placement`/`ClassSymbol`/
/// `CardName` fields.
@Suite("Investigator fixture decode")
struct InvestigatorFixtureTests {
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

    @Test("A negative unhealedHorrorThisRound decodes without clamping or failing")
    func negativeUnhealedHorrorDecodes() throws {
        let investigator = try ContractJSON.decode(
            Investigator.self, from: fixtureData(named: "investigator-unhealed-horror-negative")
        )
        #expect(investigator.unhealedHorrorThisRound == -3)
        #expect(investigator.name == CardName(title: "Roland Banks", subtitle: "The Fed"))
        #expect(investigator.investigatorClass == .guardian)
        #expect(investigator.placement.kind == .atLocation)
        #expect(investigator.traits == ["Agency", "Detective"])
        #expect(investigator.beganRoundAt != nil)
        #expect(investigator.previousLocation == nil)
        #expect(investigator.deckURL == nil)
    }

    @Test("unhealedHorrorThisRound has no lower-bound validation applied")
    func unhealedHorrorHasNoLowerBoundGuard() throws {
        var fixture = try #require(
            String(
                data: fixtureData(named: "investigator-unhealed-horror-negative"),
                encoding: .utf8
            )
        )
        fixture = fixture.replacingOccurrences(
            of: "\"unhealedHorrorThisRound\": -3", with: "\"unhealedHorrorThisRound\": -999999"
        )
        let investigator = try ContractJSON.decode(Investigator.self, from: Data(fixture.utf8))
        #expect(investigator.unhealedHorrorThisRound == -999_999)
    }

    @Test("Investigator.placement is required and non-nullable, unlike Location.placement")
    func placementIsRequiredNonNullable() throws {
        var fixture = try #require(
            String(
                data: fixtureData(named: "investigator-unhealed-horror-negative"),
                encoding: .utf8
            )
        )
        fixture = fixture.replacingOccurrences(
            of: "\"placement\": {\n    \"contents\": \"d5a66e84-c729-4066-8475-d8a155609025\",\n"
                + "    \"tag\": \"AtLocation\"\n  },",
            with: "\"placement\": null,"
        )
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(Investigator.self, from: Data(fixture.utf8))
        }
    }
}
