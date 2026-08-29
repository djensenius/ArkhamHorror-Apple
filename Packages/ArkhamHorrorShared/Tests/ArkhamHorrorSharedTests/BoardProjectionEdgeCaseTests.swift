@testable import ArkhamHorrorShared
import Testing

/// Focused edge-case coverage for ``BoardProjectionBuilder``, built from directly
/// constructed production types (see ``BoardTestFixtures``) rather than a JSON decode —
/// exercising the same production projection function the fixture-decode tests do, on
/// hand-picked boundary states that do not appear in the governed CORE fixtures
/// themselves (which carry only one of each entity kind and no enemies/assets/etc. at
/// all).
@Suite("BoardProjection — edge cases")
struct BoardProjectionEdgeCaseTests {
    // MARK: - Ordinary vs. enemy locations

    @Test("An enemy-spawned pseudo-location projects into enemyLocations, not locations")
    func enemyLocationProjectsSeparately() {
        let enemyID = BoardTestFixtures.locationID("000000000101")
        let snapshot = BoardTestFixtures.snapshot(
            locations: [(enemyID, .enemy(BoardTestFixtures.enemyLocation(id: enemyID)))]
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.locations.isEmpty)
        #expect(projection.enemyLocations.count == 1)
        #expect(projection.enemyLocations[0].id == enemyID)
    }

    @Test("An ordinary location projects into locations, not enemyLocations")
    func ordinaryLocationProjectsSeparately() {
        let ordinaryID = BoardTestFixtures.locationID("000000000102")
        let snapshot = BoardTestFixtures.snapshot(
            locations: [(ordinaryID, .ordinary(BoardTestFixtures.ordinaryLocation(id: ordinaryID)))]
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.enemyLocations.isEmpty)
        #expect(projection.locations.count == 1)
        #expect(projection.locations[0].id == ordinaryID)
    }

    // MARK: - Nullable movement / advance cost

    @Test("An investigator with no in-progress movement projects a nil movementSummary")
    func noMovementProjectsNil() {
        let investigatorID = BoardTestFixtures.investigatorID("c90001")
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [investigatorID: BoardTestFixtures.investigator(id: investigatorID)],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.investigators[0].movementSummary == nil)
    }

    @Test("An investigator with in-progress movement projects a non-nil movementSummary")
    func inProgressMovementProjectsSummary() {
        let investigatorID = BoardTestFixtures.investigatorID("c90002")
        let destinationID = BoardTestFixtures.locationID("000000000103")
        let movement = BoardTestFixtures.movement(
            means: .towardsN(2), destination: .toLocation(destinationID)
        )
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID, movement: movement
                ),
            ],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        let summary = try? #require(projection.investigators.first?.movementSummary)
        #expect(summary?.contains("2 step") == true)
    }

    @Test("An act with a nil advanceCost projects a nil advanceCostSummary")
    func nilAdvanceCostProjectsNil() {
        let actID = BoardTestFixtures.actID("c90003")
        let snapshot = BoardTestFixtures.snapshot(
            acts: [actID: BoardTestFixtures.act(id: actID, advanceCost: nil)]
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.acts[0].advanceCostSummary == nil)
    }

    @Test("An act with a present advanceCost projects its humanized tag")
    func presentAdvanceCostProjectsSummary() {
        let actID = BoardTestFixtures.actID("c90004")
        let cost = RuntimeCost(tag: "GroupClueCost", contents: nil)
        let snapshot = BoardTestFixtures.snapshot(
            acts: [actID: BoardTestFixtures.act(id: actID, advanceCost: cost)]
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.acts[0].advanceCostSummary == "Group Clue Cost")
    }

    // MARK: - Turn zero

    @Test("A scenario at turn zero projects turn 0, not an off-by-one turn 1")
    func turnZeroProjectsExactly() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(turn: 0))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.scenario?.turn == 0)
    }

    // MARK: - Negative unhealed horror

    @Test("A negative unhealedHorrorThisRound projects unclamped")
    func negativeUnhealedHorrorProjectsUnclamped() {
        let investigatorID = BoardTestFixtures.investigatorID("c90005")
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID, unhealedHorrorThisRound: -3
                ),
            ],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.investigators[0].unhealedHorrorThisRound == -3)
    }

    // MARK: - Act A-H / Agenda A-D

    @Test("Acts spanning every closed side A through H project and sort deterministically")
    func actsAcrossEverySideSortDeterministically() {
        let sides: [ActSide] = [.sideA, .sideB, .sideC, .sideD, .sideE, .sideF, .sideG, .sideH]
        var acts: [ActID: Act] = [:]
        for (index, side) in sides.enumerated() {
            let id = BoardTestFixtures.actID("c9101\(index)")
            acts[id] = BoardTestFixtures.act(
                id: id, deckID: 1, sequence: ActSequence(step: index + 1, side: side)
            )
        }
        let snapshot = BoardTestFixtures.snapshot(acts: acts)
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.acts.map(\.sequence.side) == sides)
    }

    @Test("Agendas spanning every closed side A through D project and sort deterministically")
    func agendasAcrossEverySideSortDeterministically() {
        let sides: [AgendaSide] = [.sideA, .sideB, .sideC, .sideD]
        var agendas: [AgendaID: Agenda] = [:]
        for (index, side) in sides.enumerated() {
            let id = BoardTestFixtures.agendaID("c9102\(index)")
            agendas[id] = BoardTestFixtures.agenda(
                id: id, deckID: 1, sequence: AgendaSequence(side: side, step: index + 1)
            )
        }
        let snapshot = BoardTestFixtures.snapshot(agendas: agendas)
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.agendas.map(\.sequence.side) == sides)
    }

    // MARK: - Empty optional zones

    @Test(
        "A snapshot with no acts, agendas, locations, or investigators projects explicit emptiness"
    )
    func fullyEmptySnapshotProjectsExplicitEmptyZones() {
        let snapshot = BoardTestFixtures.snapshot()
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.acts.isEmpty)
        #expect(projection.agendas.isEmpty)
        #expect(projection.locations.isEmpty)
        #expect(projection.enemyLocations.isEmpty)
        #expect(projection.investigators.isEmpty)
        #expect(BoardFocusGraphBuilder.nonEmptyZonesInCycleOrder(projection: projection) == [
            BoardFocusZone.scenario, BoardFocusZone.chaosBag,
        ])
    }

    // MARK: - Unknown/deferred open shapes

    @Test("An unrecognized phaseStep tag projects an explicit unsupported-content notice")
    func unknownPhaseStepProjectsUnsupportedNotice() throws {
        let snapshot = BoardTestFixtures.snapshot(
            phaseStep: .unknown(tag: "SomeFuturePhaseStep", rawObject: .null)
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(
            projection.counters.phaseStepSummary == BoardDisplayFormatting.unsupportedContentNotice
        )
        let containsRawTag = try #require(
            projection.counters.phaseStepSummary?.contains("SomeFuturePhaseStep")
        )
        #expect(!containsRawTag)
    }

    @Test("An unrecognized gameState tag projects an explicit unsupported-content notice")
    func unknownGameStateProjectsUnsupportedNotice() {
        let snapshot = BoardTestFixtures.snapshot(
            gameState: .unknown(tag: "SomeFutureState", rawObject: .null)
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(
            projection.counters.gameStateSummary == BoardDisplayFormatting.unsupportedContentNotice
        )
    }

    @Test(
        "A campaign-only mode (no active scenario) projects an explicit deferred campaign context"
    )
    func campaignOnlyModeProjectsExplicitDeferredContext() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .campaignOnly(.object(["tag": .string("Campaign")]))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.scenario == nil)
        #expect(projection.hasCampaignContext)
        #expect(
            BoardAccessibility.summary(scenario: nil, hasCampaignContext: true)
                .contains(BoardDisplayFormatting.unsupportedContentNotice)
        )
    }

    // MARK: - Chaos bag emptiness

    @Test("A chaos bag with only set-aside tokens is not misreported as unsupported/empty")
    func chaosBagWithOnlySetAsideTokensIsNotEmpty() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                chaosBag: BoardTestFixtures.chaosBag(
                    setAsideChaosTokens: [BoardTestFixtures.chaosToken(.skull)]
                )
            ))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(!projection.chaosBag.isEntirelyEmpty)
        #expect(projection.chaosBag.setAsideCounts.map(\.face) == [.skull])
        let summary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(!summary.contains(BoardDisplayFormatting.unsupportedContentNotice))
        #expect(summary.contains("Set aside"))
    }

    @Test("A chaos bag with only a forced-draw face is not misreported as unsupported/empty")
    func chaosBagWithOnlyForceDrawIsNotEmpty() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                chaosBag: BoardTestFixtures.chaosBag(forceDraw: .elderSign)
            ))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(!projection.chaosBag.isEntirelyEmpty)
        let summary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(!summary.contains(BoardDisplayFormatting.unsupportedContentNotice))
        #expect(summary.contains("Forced draw"))
    }

    @Test("A chaos bag with no tokens, no forced draw, and no pending choice is entirely empty")
    func chaosBagWithNothingAtAllIsEntirelyEmpty() {
        let snapshot = BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(chaosBag: BoardTestFixtures.chaosBag()))
        )
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.chaosBag.isEntirelyEmpty)
        let summary = BoardAccessibility.summary(chaosBag: projection.chaosBag)
        #expect(summary.contains(BoardDisplayFormatting.unsupportedContentNotice))
    }
}
