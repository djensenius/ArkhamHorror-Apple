@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Performance/mutation guards against a reintroduced quadratic scan, unstable
/// (randomly-ordered) identity, or repeated full-snapshot decoding in
/// ``BoardProjectionBuilder``/``BoardLayoutBuilder`` for a realistically large synthetic
/// snapshot. Uses a genuinely separate, killable subprocess under a generous hard
/// deadline (see ``SubprocessDeadlineGuard``) rather than a flaky in-process wall-clock
/// assertion, matching this package's existing quadratic-regression guard convention.
private enum BoardPerfGuardEnvironmentKey {
    static let locationCount = "BOARD_PERF_GUARD_LOCATION_COUNT"
}

@Suite("BoardProjection/BoardLayout — performance and mutation guards")
struct BoardProjectionPerformanceGuardTests {
    /// Builds a large, realistic synthetic snapshot: `count` ordinary locations chained in
    /// a corridor (each connected to its immediate neighbor, plus every third location
    /// cross-linked two steps ahead, so the topology is not merely a single straight
    /// line), one investigator per location, and one enemy/asset/treachery/event/skill/
    /// concealed entity per location — large enough that a reintroduced O(n^2) scan
    /// anywhere in the projection or layout pipeline would be readily distinguishable from
    /// this guard's generous deadline.
    static func makeLargeSnapshot(locationCount: Int) -> PublicGameSnapshot {
        var locationIDs: [LocationID] = []
        for index in 0 ..< locationCount {
            locationIDs.append(BoardTestFixtures.locationID(String(format: "%012d", index)))
        }
        var investigators: [InvestigatorID: Investigator] = [:]
        var playerOrder: [InvestigatorID] = []
        var locations: [(LocationID, Location)] = []
        for index in 0 ..< locationCount {
            let id = locationIDs[index]
            var connected: [LocationID] = []
            if index > 0 {
                connected.append(locationIDs[index - 1])
            }
            if index < locationCount - 1 {
                connected.append(locationIDs[index + 1])
            }
            if index % 3 == 0, index + 2 < locationCount {
                connected.append(locationIDs[index + 2])
            }
            let investigatorID = BoardTestFixtures.investigatorID(
                "c\(String(format: "%05d", index))"
            )
            investigators[investigatorID] = BoardTestFixtures.investigator(id: investigatorID)
            playerOrder.append(investigatorID)
            locations.append((id, .ordinary(BoardTestFixtures.ordinaryLocation(
                id: id, connectedLocations: connected, investigators: [investigatorID]
            ))))
        }
        return BoardTestFixtures.snapshot(
            locations: locations, investigators: investigators, playerOrder: playerOrder,
            activeInvestigatorID: playerOrder[0], leadInvestigatorID: playerOrder[0],
            enemyCount: locationCount, assetCount: locationCount, treacheryCount: locationCount,
            eventCount: locationCount, skillCount: locationCount, concealedCount: locationCount
        )
    }

    @Test("Projection and layout stay deterministic and complete well within a generous deadline")
    func largeSnapshotProjectionAndLayoutCompleteWithinDeadline() throws {
        // The assertions below only *report* a regression; they cannot forcibly stop a
        // still-running, non-cooperatively-cancellable tight loop. Run the actual timing
        // work in a genuinely separate, killable subprocess for real mutation-detection
        // power, per this package's established `SubprocessDeadlineGuard` convention.
        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: "boardPerformanceGuardVictimBuildLargeProjection",
            additionalEnvironment: [BoardPerfGuardEnvironmentKey.locationCount: "2500"],
            deadlineSeconds: 30
        )
        recordIfSkipped(outcome)

        // A small, fast, in-process structural check (never timing-based) that the large
        // snapshot's projection is itself correct, independent of the subprocess above.
        let snapshot = Self.makeLargeSnapshot(locationCount: 50)
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.locations.count == 50)
        #expect(projection.investigators.count == 50)
        #expect(Set(projection.locations.map(\.id)).count == 50)
        let layout = BoardLayoutBuilder.makeLayout(locations: projection.locations)
        #expect(layout.positions.count == 50)
        #expect(Set(layout.positions.values).count == 50)
    }

    @Test(
        "Repeated builds of the same large snapshot never change identity/order (no random UUIDs)"
    )
    func repeatedBuildsNeverChangeIdentityOrOrder() {
        let snapshot = Self.makeLargeSnapshot(locationCount: 200)
        let first = BoardProjectionBuilder.makeProjection(from: snapshot)
        let second = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(first == second)
        #expect(first.locations.map(\.id) == second.locations.map(\.id))
        #expect(first.investigators.map(\.id) == second.investigators.map(\.id))
    }

    private func recordIfSkipped(_ outcome: SubprocessDeadlineGuardOutcome) {
        guard case let .skippedUnsupportedHost(reason) = outcome else { return }
        _ = Issue.record(
            Comment(
                rawValue: "SubprocessDeadlineGuard's subprocess mutation-detection layer " +
                    "was skipped: \(reason). The structural assertions above already ran " +
                    "in-process and still had to pass."
            ),
            severity: .warning
        )
    }

    // MARK: - Subprocess victim

    /// Never invoked directly by the full-suite run: a no-op (instant pass) unless its
    /// environment variable is present, which only `SubprocessDeadlineGuard.runFiltered`
    /// sets. Calls `SubprocessDeadlineGuard.recordVictimCompletion()` as its very last step,
    /// strictly after its own assertions have already passed.
    @Test("Board performance guard victim: large projection/layout build (subprocess-only)")
    func boardPerformanceGuardVictimBuildLargeProjection() {
        guard
            let raw = ProcessInfo.processInfo
            .environment[BoardPerfGuardEnvironmentKey.locationCount],
            let locationCount = Int(raw)
        else {
            return
        }
        let snapshot = Self.makeLargeSnapshot(locationCount: locationCount)
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(projection.locations.count == locationCount)
        let layout = BoardLayoutBuilder.makeLayout(locations: projection.locations)
        #expect(layout.positions.count == locationCount)
        SubprocessDeadlineGuard.recordVictimCompletion()
    }
}
