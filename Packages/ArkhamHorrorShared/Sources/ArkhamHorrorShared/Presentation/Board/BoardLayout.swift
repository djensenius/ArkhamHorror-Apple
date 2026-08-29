import Foundation

/// One ordinary location's position within the deterministic semantic grid computed by
/// ``BoardLayoutBuilder``. `column` is topological distance (BFS layer) from the chosen
/// root location; `row` is this location's index within its own column after a stable,
/// non-locale-sensitive sort by raw UUID text. Never a pixel/screen coordinate: SwiftUI
/// views translate this into actual layout.
struct BoardGridPosition: Sendable, Equatable, Hashable {
    let column: Int
    let row: Int
}

/// One decorative, undirected connection between two ordinary locations, used only for
/// the noninteractive `Canvas` overlay — never a focus-graph edge on its own.
struct BoardConnectionEdge: Sendable, Equatable, Hashable {
    let first: LocationID
    let second: LocationID
}

/// The deterministic semantic layout for a scenario's ordinary-location topology.
struct BoardLayout: Sendable, Equatable {
    let positions: [LocationID: BoardGridPosition]
    /// Per-location directional neighbors, derived from real `connectedLocationIDs`
    /// topology plus each pair's relative grid position — never a distance/geometry guess
    /// independent of the actual topology. Used to declare ``FocusNode/neighbors`` edges.
    let neighbors: [LocationID: [FocusDirection: LocationID]]
    /// Every unique undirected connection, sorted deterministically, for the
    /// noninteractive connections ``Canvas``.
    let connections: [BoardConnectionEdge]
    let columnCount: Int
    let rowCount: Int
}

/// Builds a ``BoardLayout`` from a ``BoardProjection``'s ordinary locations. Pure and
/// deterministic: the same location set and topology always produce the same layout,
/// regardless of the snapshot's own map insertion order.
enum BoardLayoutBuilder {
    /// - Parameter preferredRootID: The location BFS layering starts from (typically the
    ///   active investigator's current location, so the default view centers on "here").
    ///   Falls back to the lowest-sorted location id when `nil`, absent, or unknown.
    static func makeLayout(
        locations: [BoardLocationNode], preferredRootID: LocationID? = nil
    ) -> BoardLayout {
        guard !locations.isEmpty else {
            return BoardLayout(
                positions: [:], neighbors: [:], connections: [], columnCount: 0, rowCount: 0
            )
        }
        let knownIDs = Set(locations.map(\.id))
        let adjacency = symmetricAdjacency(locations: locations, knownIDs: knownIDs)
        let sortedIDs = locations.map(\.id).sorted { $0.description < $1.description }
        let root = (preferredRootID.flatMap { knownIDs.contains($0) ? $0 : nil }) ?? sortedIDs[0]

        let columnOf = bfsColumns(root: root, sortedIDs: sortedIDs, adjacency: adjacency)
        let positions = assignRows(columnOf: columnOf, sortedIDs: sortedIDs)
        let neighbors = assignNeighbors(
            locations: locations, positions: positions, adjacency: adjacency
        )
        let connections = uniqueConnections(locations: locations, knownIDs: knownIDs)

        let columnCount = (positions.values.map(\.column).max() ?? 0) + 1
        let rowCount = (positions.values.map(\.row).max() ?? 0) + 1
        return BoardLayout(
            positions: positions, neighbors: neighbors, connections: connections,
            columnCount: columnCount, rowCount: rowCount
        )
    }

    /// The symmetric closure of `connectedLocationIDs`: an edge declared from only one
    /// side still produces neighbors on both sides, so a one-directional wire connection
    /// never silently strands the other endpoint without a return path.
    private static func symmetricAdjacency(
        locations: [BoardLocationNode], knownIDs: Set<LocationID>
    ) -> [LocationID: Set<LocationID>] {
        var adjacency: [LocationID: Set<LocationID>] = [:]
        for location in locations {
            for neighbor in location.connectedLocationIDs where knownIDs.contains(neighbor) {
                adjacency[location.id, default: []].insert(neighbor)
                adjacency[neighbor, default: []].insert(location.id)
            }
        }
        return adjacency
    }

    /// Breadth-first layering from `root`; any location unreachable from `root` (a
    /// disconnected topology component) is assigned its own trailing column afterward, in
    /// sorted-id order, rather than being omitted.
    private static func bfsColumns(
        root: LocationID, sortedIDs: [LocationID], adjacency: [LocationID: Set<LocationID>]
    ) -> [LocationID: Int] {
        var columnOf: [LocationID: Int] = [root: 0]
        var visited: Set<LocationID> = [root]
        var frontier = [root]
        var column = 0
        while !frontier.isEmpty {
            var next: [LocationID] = []
            for id in frontier {
                let neighborsSorted = (adjacency[id] ?? [])
                    .sorted { $0.description < $1.description }
                for neighbor in neighborsSorted where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    columnOf[neighbor] = column + 1
                    next.append(neighbor)
                }
            }
            frontier = next.sorted { $0.description < $1.description }
            column += 1
        }
        var nextColumn = (columnOf.values.max() ?? -1) + 1
        for id in sortedIDs where columnOf[id] == nil {
            columnOf[id] = nextColumn
            nextColumn += 1
        }
        return columnOf
    }

    private static func assignRows(
        columnOf: [LocationID: Int], sortedIDs: [LocationID]
    ) -> [LocationID: BoardGridPosition] {
        var idsByColumn: [Int: [LocationID]] = [:]
        for id in sortedIDs {
            idsByColumn[columnOf[id] ?? 0, default: []].append(id)
        }
        var positions: [LocationID: BoardGridPosition] = [:]
        for (column, ids) in idsByColumn {
            for (row, id) in ids.sorted(by: { $0.description < $1.description }).enumerated() {
                positions[id] = BoardGridPosition(column: column, row: row)
            }
        }
        return positions
    }

    /// Assigns at most one neighbor per direction from each location's real adjacency,
    /// choosing the relative direction from each pair's already-computed grid position.
    /// When more than one real neighbor would resolve to the same direction (a topology
    /// richer than 4-way), only the first (by sorted id) is declared as an explicit edge;
    /// every location still stays reachable through ``FocusWrapPolicy/wrapWithinZone``.
    private static func assignNeighbors(
        locations: [BoardLocationNode],
        positions: [LocationID: BoardGridPosition],
        adjacency: [LocationID: Set<LocationID>]
    ) -> [LocationID: [FocusDirection: LocationID]] {
        var neighbors: [LocationID: [FocusDirection: LocationID]] = [:]
        for location in locations {
            guard let position = positions[location.id] else { continue }
            var directions: [FocusDirection: LocationID] = [:]
            let sortedNeighborIDs = (adjacency[location.id] ?? [])
                .sorted { $0.description < $1.description }
            for neighborID in sortedNeighborIDs {
                guard let neighborPosition = positions[neighborID] else { continue }
                let direction = relativeDirection(from: position, to: neighborPosition)
                if directions[direction] == nil {
                    directions[direction] = neighborID
                }
            }
            neighbors[location.id] = directions
        }
        return neighbors
    }

    private static func relativeDirection(
        from origin: BoardGridPosition, to target: BoardGridPosition
    ) -> FocusDirection {
        if target.column != origin.column {
            return target.column > origin.column ? .right : .left
        }
        return target.row > origin.row ? .down : .up
    }

    private static func uniqueConnections(
        locations: [BoardLocationNode], knownIDs: Set<LocationID>
    ) -> [BoardConnectionEdge] {
        var seen: Set<BoardConnectionEdge> = []
        var edges: [BoardConnectionEdge] = []
        for location in locations {
            for neighborID in location.connectedLocationIDs where knownIDs.contains(neighborID) {
                let ordered = [location.id, neighborID].sorted { $0.description < $1.description }
                let edge = BoardConnectionEdge(first: ordered[0], second: ordered[1])
                guard !seen.contains(edge) else { continue }
                seen.insert(edge)
                edges.append(edge)
            }
        }
        return edges.sorted {
            ($0.first.description, $0.second.description)
                < ($1.first.description, $1.second.description)
        }
    }
}
