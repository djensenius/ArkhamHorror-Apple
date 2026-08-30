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

    // MARK: - Chaos bag: no active scenario / empty / populated

    @Test("No active scenario projects .noActiveScenario, announced as such, never unsupported")
    func chaosBagWithNoActiveScenarioAnnouncesNoActiveScenario() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .campaignOnly(.object(["tag": .string("Campaign")]))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.chaosBag == .noActiveScenario)
        #expect(projection.chaosBag.displayState == .noActiveScenario)
        let summary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(summary.contains("No active scenario"))
        #expect(!summary.contains(BoardDisplayFormatting.unsupportedContentNotice))
    }

    @Test(
        """
        A fully decoded, genuinely empty scenario chaos bag displays/announces neutral \
        emptiness, never the unsupported-content notice
        """
    )
    func chaosBagFullyEmptyAnnouncesNeutralEmptyNeverUnsupported() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(chaosBag: BoardTestFixtures.chaosBag()))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.chaosBag.displayState == .empty)
        let summary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(summary.contains("Empty"))
        #expect(!summary.contains(BoardDisplayFormatting.unsupportedContentNotice))
        #expect(!summary.contains("No active scenario"))
    }

    @Test("A chaos bag with only set-aside tokens displays/announces as populated, not empty")
    func chaosBagWithOnlySetAsideTokensIsPopulated() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                chaosBag: BoardTestFixtures.chaosBag(
                    setAsideChaosTokens: [BoardTestFixtures.chaosToken(.skull)]
                )
            ))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        guard case let .populated(summary) = projection.chaosBag.displayState else {
            Issue.record("Expected .populated")
            return
        }
        #expect(summary.setAsideCounts.map(\.face) == [.skull])
        let accessibilitySummary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(!accessibilitySummary.contains(BoardDisplayFormatting.unsupportedContentNotice))
        #expect(!accessibilitySummary.contains("Empty"))
        #expect(accessibilitySummary.contains("Set aside"))
    }

    @Test("A chaos bag with only a forced-draw face displays/announces as populated, not empty")
    func chaosBagWithOnlyForceDrawIsPopulated() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                chaosBag: BoardTestFixtures.chaosBag(forceDraw: .elderSign)
            ))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        guard case .populated = projection.chaosBag.displayState else {
            Issue.record("Expected .populated")
            return
        }
        let summary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(!summary.contains(BoardDisplayFormatting.unsupportedContentNotice))
        #expect(!summary.contains("Empty"))
        #expect(summary.contains("Forced draw"))
    }

    @Test("A campaign+scenario mode reads the typed scenario's own chaos bag, not the campaign")
    func campaignAndScenarioModeReadsTypedScenarioChaosBag() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .campaignAndScenario(
                campaign: .object(["tag": .string("Campaign")]),
                scenario: BoardTestFixtures.scenario(chaosBag: BoardTestFixtures.chaosBag())
            )
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        // Must resolve through the typed `Scenario.chaosBag` this mode still carries —
        // never fall back to `.noActiveScenario` just because a `This` campaign package
        // is also present, and never substitute anything derived from that campaign's
        // own broad, unrelated JSONValue payload.
        #expect(projection.chaosBag.displayState == .empty)
        #expect(projection.hasCampaignContext)
    }
}
