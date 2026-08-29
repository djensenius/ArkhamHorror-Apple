@testable import ArkhamHorrorShared
import Foundation
import Testing

/// High-risk projection coverage: decodes the exact governed, non-empty CORE `get-game`/
/// `game-update` fixture bytes through production `ContractJSON`, and asserts
/// ``BoardProjectionBuilder`` produces an equal, deterministically-ordered, stably-
/// identified projection from both — the same core invariant
/// ``PublicGameSnapshotFixtureTests`` already asserts for the underlying snapshot itself,
/// one layer up.
@Suite("BoardProjection — governed fixture decode")
struct BoardProjectionFixtureTests {
    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    private func restProjection() throws -> BoardProjection {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: fixtureData(named: "get-game")
        )
        return BoardProjectionBuilder.makeProjection(from: envelope.game)
    }

    private func webSocketProjection() throws -> BoardProjection {
        let update = try ContractJSON.decode(
            BoardSnapshotUpdate.self, from: fixtureData(named: "game-update")
        )
        guard case let .snapshot(snapshot) = update else {
            Issue.record("Expected a .snapshot GameUpdate")
            return BoardProjectionBuilder.makeProjection(from: envelopeFallback())
        }
        return BoardProjectionBuilder.makeProjection(from: snapshot)
    }

    /// Only reached if `webSocketProjection()`'s own `Issue.record` above already failed
    /// the test; provides a same-typed fallback value so that helper can still return.
    private func envelopeFallback() -> PublicGameSnapshot {
        BoardTestFixtures.snapshot()
    }

    @Test("The REST and WebSocket fixtures build an equal BoardProjection")
    func restAndWebSocketProjectionsAreEqual() throws {
        let rest = try restProjection()
        let webSocket = try webSocketProjection()
        #expect(rest == webSocket)
    }

    @Test("The projection's game name and scenario summary decode from the governed fixture")
    func gameNameAndScenarioDecode() throws {
        let projection = try restProjection()
        #expect(projection.gameName == "Contract fixture game")
        #expect(projection.hasCampaignContext == false)
        let scenario = try #require(projection.scenario)
        #expect(scenario.displayName == "The Gathering")
        #expect(scenario.difficulty == .easy)
        #expect(scenario.turn == 1)
    }

    @Test("The projection's single ordinary location decodes with stable identity and topology")
    func singleOrdinaryLocationDecodes() throws {
        let projection = try restProjection()
        #expect(projection.locations.count == 1)
        #expect(projection.enemyLocations.isEmpty)
        let location = try #require(projection.locations.first)
        #expect(location.displayLabel == "study")
        #expect(location.revealed)
        #expect(location.investigatorIDs.map(\.description) == ["c01001"])
        #expect(location.connectedLocationIDs.isEmpty)
        #expect(location.clueCount == 2)
    }

    @Test("The projection's single investigator decodes with a safe display name")
    func singleInvestigatorDecodes() throws {
        let projection = try restProjection()
        #expect(projection.investigators.count == 1)
        let investigator = try #require(projection.investigators.first)
        #expect(investigator.displayName == "Roland Banks")
        #expect(investigator.subtitle == "The Fed")
        #expect(investigator.investigatorClass == .guardian)
        #expect(investigator.health == 9)
        #expect(investigator.isActiveInvestigator)
        #expect(investigator.currentLocationID == projection.locations.first?.id)
    }

    @Test("The projection's single act/agenda decode with their closed sequence sides")
    func actAndAgendaDecode() throws {
        let projection = try restProjection()
        let act = try #require(projection.acts.first)
        #expect(act.sequence == ActSequence(step: 1, side: .sideA))
        #expect(act.advanceCostSummary != nil)
        let agenda = try #require(projection.agendas.first)
        #expect(agenda.sequence == AgendaSequence(side: .sideA, step: 1))
        #expect(agenda.doomThresholdSummary == "3")
    }

    @Test("The projection's entity counters mirror the fixture's empty broad entity maps")
    func entityCountersMirrorFixture() throws {
        let projection = try restProjection()
        let counters = projection.counters.entityCounters
        #expect(counters.enemies == 0)
        #expect(counters.assets == 0)
        #expect(counters.treacheries == 0)
        #expect(counters.events == 0)
        #expect(counters.skills == 0)
        #expect(counters.concealed == 0)
        #expect(projection.counters.pendingPromptCount == 1)
    }

    @Test("Accessibility summaries are non-empty, stable sentences for every fixture entity")
    func accessibilitySummariesAreNonEmpty() throws {
        let projection = try restProjection()
        let scenarioSummary = BoardAccessibility.summary(
            scenario: projection.scenario, hasCampaignContext: projection.hasCampaignContext
        )
        #expect(!scenarioSummary.isEmpty)
        for location in projection.locations {
            #expect(!BoardAccessibility.summary(location: location).isEmpty)
        }
        for investigator in projection.investigators {
            #expect(!BoardAccessibility.summary(investigator: investigator).isEmpty)
        }
        for act in projection.acts {
            #expect(!BoardAccessibility.summary(act: act).isEmpty)
        }
        for agenda in projection.agendas {
            #expect(!BoardAccessibility.summary(agenda: agenda).isEmpty)
        }
        #expect(!BoardAccessibility.summary(counters: projection.counters).isEmpty)
        #expect(!BoardAccessibility.summary(chaosBag: projection.chaosBag).isEmpty)
    }

    @Test("Building the projection twice from the same decoded snapshot is fully deterministic")
    func projectionBuildIsDeterministic() throws {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: fixtureData(named: "get-game")
        )
        let first = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let second = BoardProjectionBuilder.makeProjection(from: envelope.game)
        #expect(first == second)
    }
}
