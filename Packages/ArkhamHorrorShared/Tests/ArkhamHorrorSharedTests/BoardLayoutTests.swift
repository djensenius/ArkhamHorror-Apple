@testable import ArkhamHorrorShared
import Testing

/// Coverage for ``BoardLayoutBuilder``'s deterministic BFS grid layout and neighbor
/// derivation.
@Suite("BoardLayout — deterministic grid layout")
struct BoardLayoutTests {
    private func fourLocationCycle() -> [BoardLocationNode] {
        // A ring: north -- east -- south -- west -- north.
        let north = BoardTestFixtures.locationID("000000000201")
        let east = BoardTestFixtures.locationID("000000000202")
        let south = BoardTestFixtures.locationID("000000000203")
        let west = BoardTestFixtures.locationID("000000000204")
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(locations: [
                (north, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: north, connectedLocations: [east, west]
                ))),
                (east, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: east, connectedLocations: [north, south]
                ))),
                (south, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: south, connectedLocations: [east, west]
                ))),
                (west, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: west, connectedLocations: [north, south]
                ))),
            ])
        )
        return projection.locations
    }

    @Test("Layout is fully deterministic across repeated builds of the same topology")
    func layoutIsDeterministic() {
        let locations = fourLocationCycle()
        let first = BoardLayoutBuilder.makeLayout(locations: locations)
        let second = BoardLayoutBuilder.makeLayout(locations: locations)
        #expect(first == second)
    }

    @Test("Every location receives a distinct grid position")
    func everyLocationReceivesADistinctPosition() {
        let locations = fourLocationCycle()
        let layout = BoardLayoutBuilder.makeLayout(locations: locations)
        let positions = Set(layout.positions.values)
        #expect(positions.count == locations.count)
    }

    @Test("A one-directional wire connection still produces a symmetric neighbor edge")
    func oneDirectionalConnectionProducesSymmetricEdge() {
        let first = BoardTestFixtures.locationID("000000000205")
        let second = BoardTestFixtures.locationID("000000000206")
        // Only `first` declares the connection; `second` does not declare it back.
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(locations: [
                (first, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: first, connectedLocations: [second]
                ))),
                (second, .ordinary(BoardTestFixtures.ordinaryLocation(id: second))),
            ])
        )
        let layout = BoardLayoutBuilder.makeLayout(locations: projection.locations)
        let firstNeighbors = layout.neighbors[first] ?? [:]
        let secondNeighbors = layout.neighbors[second] ?? [:]
        #expect(firstNeighbors.values.contains(second))
        #expect(secondNeighbors.values.contains(first))
    }

    @Test("A single, isolated location gets exactly one 1x1 layout with no connections")
    func singleLocationLayout() {
        let id = BoardTestFixtures.locationID("000000000207")
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                locations: [(id, .ordinary(BoardTestFixtures.ordinaryLocation(id: id)))]
            )
        )
        let layout = BoardLayoutBuilder.makeLayout(locations: projection.locations)
        #expect(layout.positions.count == 1)
        #expect(layout.connections.isEmpty)
        #expect(layout.columnCount == 1)
        #expect(layout.rowCount == 1)
    }

    @Test("An empty location list produces an empty, zero-sized layout")
    func emptyLocationsProduceEmptyLayout() {
        let layout = BoardLayoutBuilder.makeLayout(locations: [])
        #expect(layout.positions.isEmpty)
        #expect(layout.columnCount == 0)
        #expect(layout.rowCount == 0)
    }

    @Test("Disconnected components each still receive a deterministic, non-overlapping position")
    func disconnectedComponentsGetDeterministicPositions() {
        let islandA = BoardTestFixtures.locationID("000000000208")
        let islandB = BoardTestFixtures.locationID("000000000209")
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(locations: [
                (islandA, .ordinary(BoardTestFixtures.ordinaryLocation(id: islandA))),
                (islandB, .ordinary(BoardTestFixtures.ordinaryLocation(id: islandB))),
            ])
        )
        let first = BoardLayoutBuilder.makeLayout(locations: projection.locations)
        let second = BoardLayoutBuilder.makeLayout(locations: projection.locations)
        #expect(first == second)
        #expect(Set(first.positions.values).count == 2)
    }
}
