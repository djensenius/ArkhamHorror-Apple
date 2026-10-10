@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BoardChaosBagView — structural invariants")
struct BoardChaosBagViewStructureTests {
    @Test("Linked chaos-token targets are siblings of the summary tile")
    func linkedChaosTokenTargetsAreSiblingsOfSummaryTile() throws {
        // SwiftUI's runtime accessibility hierarchy is not exposed to SwiftPM tests here,
        // and this package does not carry a view-inspection dependency. This source-level
        // invariant pins the important structure instead: actionable token controls must
        // be emitted beside the summary tile, never inside the BoardEntityTile button label.
        let source = try String(contentsOf: boardScenarioViewURL(), encoding: .utf8)
        let body = try #require(source.slice(
            after: "var body: some View {",
            before: "@ViewBuilder private var chaosBagContent"
        ))
        let summaryIndex = try #require(body.range(of: "summaryTile")?.lowerBound)
        let targetsIndex = try #require(body.range(of: "linkedChaosTokenTargets")?.lowerBound)

        #expect(body.contains("VStack(alignment: .leading"))
        #expect(summaryIndex < targetsIndex)

        let summaryTile = try #require(source.slice(
            after: "private var summaryTile: some View {",
            before: "@ViewBuilder private var chaosBagContent"
        ))
        #expect(summaryTile.contains("BoardEntityTile("))
        #expect(!summaryTile.contains("linkedChaosTokenTargets"))
    }

    private func boardScenarioViewURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ArkhamHorrorSharedTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ArkhamHorrorShared
            .appendingPathComponent(
                "Sources/ArkhamHorrorShared/Presentation/Board/BoardScenarioAndCountersView.swift"
            )
    }
}

private extension String {
    func slice(after start: String, before end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound ..< endIndex)
        else { return nil }
        return String(self[startRange.upperBound ..< endRange.lowerBound])
    }
}
