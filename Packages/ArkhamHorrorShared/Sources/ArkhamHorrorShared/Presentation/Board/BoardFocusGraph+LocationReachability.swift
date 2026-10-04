import Foundation

extension BoardFocusGraphBuilder {
    static func repairLocationHeaderReachability(
        locations: [BoardLocationNode],
        rootID: LocationID,
        headerNeighbors: inout [LocationID: [FocusDirection: SemanticFocusID]],
        actionNeighbors: [LocationID: [FocusDirection: SemanticFocusID]]
    ) {
        let locationIDs = locations.map(\.id)
        guard locationIDs.count > 1 else { return }
        var reachable = reachableLocationHeaders(
            from: rootID,
            headerNeighbors: headerNeighbors,
            actionNeighbors: actionNeighbors
        )
        while let missingID = locationIDs.first(where: { !reachable.contains($0) }) {
            let missingIndex = locationIDs.firstIndex(of: missingID) ?? 0
            let sourceID = reachableHeaderBefore(
                index: missingIndex,
                locationIDs: locationIDs,
                reachable: reachable
            ) ?? rootID
            headerNeighbors[sourceID, default: [:]][.right] = BoardFocusID.location(missingID)
            headerNeighbors[missingID, default: [:]][.left] = BoardFocusID.location(sourceID)
            reachable = reachableLocationHeaders(
                from: rootID,
                headerNeighbors: headerNeighbors,
                actionNeighbors: actionNeighbors
            )
        }
    }

    private static func reachableHeaderBefore(
        index: Int,
        locationIDs: [LocationID],
        reachable: Set<LocationID>
    ) -> LocationID? {
        for offset in 1 ..< locationIDs.count {
            let candidate = locationIDs[(index - offset + locationIDs.count) % locationIDs.count]
            if reachable.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func reachableLocationHeaders(
        from rootID: LocationID,
        headerNeighbors: [LocationID: [FocusDirection: SemanticFocusID]],
        actionNeighbors: [LocationID: [FocusDirection: SemanticFocusID]]
    ) -> Set<LocationID> {
        var visited: Set<SemanticFocusID> = []
        var queue = [BoardFocusID.location(rootID)]
        while let current = queue.first {
            queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            for next in focusNeighbors(
                from: current,
                headerNeighbors: headerNeighbors,
                actionNeighbors: actionNeighbors
            ) where !visited.contains(next) {
                queue.append(next)
            }
        }
        return Set(headerNeighbors.keys.filter { visited.contains(BoardFocusID.location($0)) })
    }

    private static func focusNeighbors(
        from focusID: SemanticFocusID,
        headerNeighbors: [LocationID: [FocusDirection: SemanticFocusID]],
        actionNeighbors: [LocationID: [FocusDirection: SemanticFocusID]]
    ) -> [SemanticFocusID] {
        for (locationID, neighbors) in headerNeighbors {
            guard BoardFocusID.location(locationID) == focusID else { continue }
            return Array(neighbors.values)
        }
        for (locationID, neighbors) in actionNeighbors {
            guard BoardFocusID.locationEnemyActions(locationID) == focusID else { continue }
            return Array(neighbors.values)
        }
        return []
    }
}
