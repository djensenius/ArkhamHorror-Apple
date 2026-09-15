@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Authenticated Cover Up production replay evidence")
struct ProductionCoverUpReplayEvidenceTests {
    @Test("Artifact bytes and authenticated provenance remain exact")
    func artifactProvenanceIsExact() throws {
        let (data, evidence) = try loadEvidence()

        #expect(data.count == ProductionCoverUpReplayEvidence.expectedByteCount)
        try evidence.validateProvenance()
    }

    @Test("Use and skip decode the exact production Q33 and Q34 snapshots")
    func useAndSkipOutcomesAreExact() throws {
        let (_, evidence) = try loadEvidence()

        try evidence.validateResolvedOutcomes()
        #expect(evidence.use.clueDelta == ProductionCoverUpReplayClues(
            coverUp: -1,
            investigator: 0,
            location: 0
        ))
        #expect(evidence.skip.clueDelta == ProductionCoverUpReplayClues(
            coverUp: 0,
            investigator: 1,
            location: -1
        ))
        #expect(evidence.use.resultingQuestionVersion == 34)
        #expect(evidence.skip.resultingQuestionVersion == 34)
    }

    @Test("A stale Q32 answer preserves the strict actionable Q33 snapshot")
    func staleAnswerLeavesQ33Unchanged() throws {
        let (_, evidence) = try loadEvidence()

        try evidence.validateStaleOutcome()
        #expect(evidence.stale.cluesAfter == evidence.stale.cluesBefore)
        #expect(evidence.stale.stateAfterSHA256
            == evidence.stale.stateBeforeSHA256)
        #expect(evidence.stale.resultingQuestionVersion == 33)
    }

    private func loadEvidence() throws -> (
        data: Data,
        evidence: ProductionCoverUpReplayEvidence
    ) {
        let url = try #require(Bundle.module.url(
            forResource: "cover-up-production-replay",
            withExtension: "json",
            subdirectory: "Fixtures/Replay"
        ))
        let data = try Data(contentsOf: url)
        #expect(
            LocaleCatalogLoader.sha256Hex(data)
                == ProductionCoverUpReplayEvidence.artifactSHA256
        )

        let original = try LosslessJSONParser.parse(data)
        let evidence = try ContractJSON.decode(
            ProductionCoverUpReplayEvidence.self,
            from: data
        )
        let reencoded = try LosslessJSONParser.parse(
            ContractJSON.encode(evidence)
        )
        #expect(original == reencoded)
        return (data, evidence)
    }
}
