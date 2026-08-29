import Foundation

/// The shared conformance set for a stable, `String`-backed, human-readable
/// identifier type. Factored out purely so ``SemanticFocusID`` and
/// ``SemanticFocusZone``'s declarations fit on one line each.
private typealias StableStringIdentifier = CustomStringConvertible & ExpressibleByStringLiteral &
    Hashable & RawRepresentable & Sendable

/// A stable, author-declared identifier for one focusable element in the
/// semantic focus graph — never a screen coordinate or view index, so focus
/// state survives layout changes and remains meaningful across snapshots.
public struct SemanticFocusID: StableStringIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }
}

/// A stable, author-declared grouping of ``SemanticFocusID``s (for example a
/// hand, a play area, or a prompt surface) used for wrap-within-zone
/// navigation and zone entry-point fallback.
public struct SemanticFocusZone: StableStringIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }
}

/// How ``FocusGraph/neighbor(from:direction:)`` resolves a direction with no
/// explicit ``FocusNode/neighbors`` entry.
public enum FocusWrapPolicy: Hashable, Sendable {
    /// Missing edges never move focus.
    case noWrap
    /// Missing edges wrap to the first/last member of the current node's own
    /// zone, in declared insertion order.
    case wrapWithinZone
}

/// One node's explicit, author-declared adjacency. Only listed directions are
/// navigable; a direction with no entry is resolved by ``FocusWrapPolicy``,
/// never guessed from on-screen geometry.
public struct FocusNode: Sendable {
    public let id: SemanticFocusID
    public let zone: SemanticFocusZone
    public var neighbors: [FocusDirection: SemanticFocusID]
    /// The deterministic fallback target used when this node is the current
    /// focus and is removed. `nil` defers to the zone's declared entry point
    /// (see ``FocusGraph/zoneEntryPoints``), and then to the graph's first
    /// remaining node in declared insertion order — never an arbitrary or
    /// unspecified choice.
    public var removalFallback: SemanticFocusID?

    public init(
        id: SemanticFocusID,
        zone: SemanticFocusZone,
        neighbors: [FocusDirection: SemanticFocusID] = [:],
        removalFallback: SemanticFocusID? = nil
    ) {
        self.id = id
        self.zone = zone
        self.neighbors = neighbors
        self.removalFallback = removalFallback
    }
}

/// A deterministic, explicit-adjacency focus graph.
///
/// Every edge is author-declared (``FocusNode/neighbors``); geometry (screen
/// position, view frame, or hit-testing) never overrides or substitutes for an
/// explicit edge. Nodes are retained in insertion order (``order``) so any
/// fallback that must choose among several equally valid candidates resolves
/// the same way every time, independent of `Dictionary` iteration order.
public struct FocusGraph: Sendable {
    public private(set) var nodes: [SemanticFocusID: FocusNode] = [:]
    /// Insertion order, preserved for deterministic wrap and fallback
    /// resolution. Not necessarily related to on-screen layout order.
    public private(set) var order: [SemanticFocusID] = []
    /// Each zone's declared entry point: the target used as a removal
    /// fallback when a node has none of its own, and as the default focus
    /// when a modal presentation names a zone rather than one specific node.
    public var zoneEntryPoints: [SemanticFocusZone: SemanticFocusID]
    public var wrapPolicy: FocusWrapPolicy

    public init(
        nodes: [FocusNode] = [],
        zoneEntryPoints: [SemanticFocusZone: SemanticFocusID] = [:],
        wrapPolicy: FocusWrapPolicy = .noWrap
    ) {
        self.zoneEntryPoints = zoneEntryPoints
        self.wrapPolicy = wrapPolicy
        for node in nodes {
            insert(node)
        }
    }

    /// Whether `id` currently exists in the graph.
    public func contains(_ id: SemanticFocusID) -> Bool {
        nodes[id] != nil
    }

    public func node(for id: SemanticFocusID) -> FocusNode? {
        nodes[id]
    }

    /// Inserts or replaces `node`. A replacement keeps its original position
    /// in ``order`` so an unrelated re-declaration of an existing node (for
    /// example, refreshed neighbor edges after a state update) never disturbs
    /// tie-break/fallback determinism for other nodes.
    public mutating func insert(_ node: FocusNode) {
        if nodes[node.id] == nil {
            order.append(node.id)
        }
        nodes[node.id] = node
    }

    /// Removes `id`. Any other node whose edge pointed at `id` has that edge
    /// cleared, and any zone entry point naming `id` is cleared, so no
    /// remaining node or zone can ever resolve to a removed target.
    public mutating func remove(_ id: SemanticFocusID) {
        guard nodes[id] != nil else { return }
        nodes[id] = nil
        order.removeAll { $0 == id }
        for existingID in order {
            guard var existing = nodes[existingID] else { continue }
            existing.neighbors = existing.neighbors.filter { $0.value != id }
            nodes[existingID] = existing
        }
        zoneEntryPoints = zoneEntryPoints.filter { $0.value != id }
    }

    /// Resolves the neighbor for `direction` from `id`: the explicit declared
    /// edge if its target still exists, else the ``wrapPolicy`` result, else
    /// `nil` (focus does not move).
    public func neighbor(from id: SemanticFocusID, direction: FocusDirection) -> SemanticFocusID? {
        guard let node = nodes[id] else { return nil }
        if let explicit = node.neighbors[direction], nodes[explicit] != nil {
            return explicit
        }
        guard wrapPolicy == .wrapWithinZone else { return nil }
        let zoneMembers = order.filter { nodes[$0]?.zone == node.zone }
        guard zoneMembers.count > 1, let index = zoneMembers.firstIndex(of: id) else {
            return nil
        }
        switch direction {
        case .right, .down:
            return zoneMembers[(index + 1) % zoneMembers.count]
        case .left, .up:
            return zoneMembers[(index - 1 + zoneMembers.count) % zoneMembers.count]
        }
    }

    /// The deterministic fallback target when `previousZone`/`declaredFallback`
    /// (typically a just-removed node's own zone and
    /// ``FocusNode/removalFallback``) can no longer be honored directly:
    /// `declaredFallback` if it still exists, else `previousZone`'s declared
    /// entry point if it still exists, else the first remaining node in
    /// ``order`` — never an unspecified or dictionary-order-dependent choice.
    public func fallbackTarget(
        previousZone: SemanticFocusZone? = nil,
        declaredFallback: SemanticFocusID? = nil
    ) -> SemanticFocusID? {
        if let declaredFallback, nodes[declaredFallback] != nil {
            return declaredFallback
        }
        if let previousZone, let entry = zoneEntryPoints[previousZone], nodes[entry] != nil {
            return entry
        }
        return order.first
    }

    /// Restores focus deterministically: `preferred` unchanged if it still
    /// exists (making repeated calls with an unchanged graph and the same
    /// `preferred` idempotent), else the ``fallbackTarget(previousZone:declaredFallback:)``
    /// resolution.
    public func restoreFocus(
        preferred: SemanticFocusID?,
        previousZone: SemanticFocusZone? = nil,
        declaredFallback: SemanticFocusID? = nil
    ) -> SemanticFocusID? {
        if let preferred, nodes[preferred] != nil {
            return preferred
        }
        return fallbackTarget(previousZone: previousZone, declaredFallback: declaredFallback)
    }
}
