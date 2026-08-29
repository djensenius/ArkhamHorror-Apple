import Foundation

/// A small, deterministic focus graph fixture used by ``SemanticInputHarnessView``
/// and its tests: a 2×2 "board" zone with full directional adjacency and
/// zone-wrap enabled, plus a one-node "menu" zone reached only through a
/// modal presentation (see ``SemanticInputHarnessModel``).
enum SemanticInputHarnessFixture {
    static let boardZone: SemanticFocusZone = "board"
    static let menuZone: SemanticFocusZone = "menu"

    static let boardSeatOne: SemanticFocusID = "board.seat-1"
    static let boardSeatTwo: SemanticFocusID = "board.seat-2"
    static let boardSeatThree: SemanticFocusID = "board.seat-3"
    static let boardSeatFour: SemanticFocusID = "board.seat-4"
    static let menuClose: SemanticFocusID = "menu.close"

    static func makeGraph() -> FocusGraph {
        FocusGraph(
            nodes: [
                FocusNode(
                    id: boardSeatOne, zone: boardZone,
                    neighbors: [.right: boardSeatTwo, .down: boardSeatThree]
                ),
                FocusNode(
                    id: boardSeatTwo, zone: boardZone,
                    neighbors: [.left: boardSeatOne, .down: boardSeatFour]
                ),
                FocusNode(
                    id: boardSeatThree, zone: boardZone,
                    neighbors: [.up: boardSeatOne, .right: boardSeatFour]
                ),
                FocusNode(
                    id: boardSeatFour, zone: boardZone,
                    neighbors: [.up: boardSeatTwo, .left: boardSeatThree]
                ),
                FocusNode(id: menuClose, zone: menuZone),
            ],
            zoneEntryPoints: [boardZone: boardSeatOne, menuZone: menuClose],
            wrapPolicy: .wrapWithinZone
        )
    }
}
