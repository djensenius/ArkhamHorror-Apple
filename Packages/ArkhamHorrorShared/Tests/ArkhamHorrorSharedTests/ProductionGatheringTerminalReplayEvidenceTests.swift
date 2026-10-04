@testable import ArkhamHorrorShared
import Testing

@Suite("Gathering terminal replay validator")
struct GatheringTerminalReplayEvidenceTests {
    private let factory = GatheringTerminalReplayFixtureFactory()

    @Test("Terminal route evidence accepts Q42 through Q70 and terminal states")
    func validTerminalEvidence() throws {
        let fixture = try factory.terminalEvidence()

        try fixture.evidence.validate(
            promptIdentity: fixture.identity,
            playerID: fixture.playerID
        )
        #expect(fixture.evidence.steps.map(\.prompt.version) == Array(42 ... 70))
        #expect(fixture.evidence.defeatState.scenarioSteps == 68)
        #expect(fixture.evidence.terminalState.scenarioSteps == 70)
        #expect(fixture.evidence.terminalState.gameStateSummary == "Over")
    }

    @Test("Terminal route rejects count, role, version, and actionability drift")
    func terminalRouteDriftFailsClosed() throws {
        let fixture = try factory.terminalEvidence()

        try expectTerminalReplayRejected(
            GatheringTerminalReplayEvidence(
                steps: Array(fixture.evidence.steps.dropLast()),
                defeatState: fixture.evidence.defeatState,
                terminalState: fixture.evidence.terminalState
            ),
            fixture: fixture
        )
        try expectTerminalReplayRejected(
            factory.replacing(
                fixture.evidence,
                at: ["steps", "0", "role"],
                with: .string(GatheringTerminalChoiceRole.endTurn.rawValue)
            ),
            fixture: fixture
        )
        try expectTerminalReplayRejected(
            factory.replacing(
                fixture.evidence,
                at: ["steps", "1", "prompt", "version"],
                with: .number(.integer(999))
            ),
            fixture: fixture
        )
        try expectTerminalReplayRejected(
            factory.replacing(
                fixture.evidence,
                at: ["steps", "0", "prompt", "actionableSourceIndices"],
                with: .array([])
            ),
            fixture: fixture
        )
    }

    @Test("Terminal state digest rejects byte tampering")
    func terminalStateDigestTamperingFailsClosed() throws {
        let fixture = try factory.terminalEvidence()
        try fixture.evidence.defeatState.validateDigest()

        let tampered: GatheringTerminalStateEvidence = try factory.replacing(
            fixture.evidence.defeatState,
            at: ["summaryCanonicalSHA256"],
            with: .string(String(repeating: "0", count: 64))
        )
        #expect(
            throws: ProductionGatheringActReplayEvidenceError.digestMismatch
        ) {
            try tampered.validateDigest()
        }
    }

    @Test("Terminal replay rejects defeat, terminal, and missing Cover Up state drift")
    func terminalStateDriftFailsClosed() throws {
        let fixture = try factory.terminalEvidence()
        let wrongStep = try factory.defeatState(scenarioSteps: 69)
        let wrongHorror = try factory.defeatState(horror: 6)
        let wrongTerminal = try factory.terminalState(gameState: .active)
        let missingCoverUp = try factory.defeatStateWithoutCoverUp()

        try expectTerminalReplayRejected(
            fixture.replacing(defeatState: wrongStep),
            fixture: fixture
        )
        try expectTerminalReplayRejected(
            fixture.replacing(defeatState: wrongHorror),
            fixture: fixture
        )
        try expectTerminalReplayRejected(
            fixture.replacing(terminalState: wrongTerminal),
            fixture: fixture
        )
        try expectTerminalReplayRejected(
            fixture.replacing(defeatState: missingCoverUp),
            fixture: fixture
        )
    }

    private func expectTerminalReplayRejected(
        _ evidence: GatheringTerminalReplayEvidence,
        fixture: GatheringTerminalReplayFixture
    ) throws {
        #expect(
            throws: ProductionGatheringActReplayEvidenceError
                .invalidTerminalReplay
        ) {
            try evidence.validate(
                promptIdentity: fixture.identity,
                playerID: fixture.playerID
            )
        }
    }
}
