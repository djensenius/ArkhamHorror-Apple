@testable import ArkhamHorrorShared
import SwiftUI
import Testing

@MainActor
@Suite("Controller input ownership")
struct ControllerInputOwnershipCoordinatorTests {
    private final class OwnerToken {}

    @Test("Active scene claims route controller input back to that board")
    func activeSceneClaimsRouteControllerInputBackToThatBoard() {
        let coordinator = ControllerInputOwnershipCoordinator()
        let firstBoard = BoardControllerInputOwner()
        let secondBoard = BoardControllerInputOwner()

        coordinator.claim(firstBoard)
        coordinator.claim(secondBoard)
        BoardControllerInputSceneOwnership.scenePhaseDidChange(
            .inactive,
            owner: firstBoard,
            coordinator: coordinator
        )
        #expect(!coordinator.canDispatch(for: firstBoard))
        #expect(coordinator.canDispatch(for: secondBoard))

        BoardControllerInputSceneOwnership.scenePhaseDidChange(
            .active,
            owner: firstBoard,
            coordinator: coordinator
        )
        #expect(coordinator.canDispatch(for: firstBoard))
        #expect(!coordinator.canDispatch(for: secondBoard))
    }

    @Test("Board controller dispatch gate only invokes the active owner")
    func boardControllerDispatchGateOnlyInvokesTheActiveOwner() {
        let coordinator = ControllerInputOwnershipCoordinator()
        let activeBoard = BoardControllerInputOwner()
        let inactiveBoard = BoardControllerInputOwner()
        var handled: [SemanticDispatchOutcome] = []
        coordinator.claim(activeBoard)

        #expect(!BoardControllerInputDispatchGate.dispatch(
            .command(.primaryAction),
            owner: inactiveBoard,
            coordinator: coordinator,
            handler: { handled.append($0) }
        ))
        #expect(handled.isEmpty)
        #expect(BoardControllerInputDispatchGate.dispatch(
            .command(.primaryAction),
            owner: activeBoard,
            coordinator: coordinator,
            handler: { handled.append($0) }
        ))
        #expect(handled == [.command(.primaryAction)])
    }

    @Test("Only the current input owner may dispatch controller events")
    func onlyCurrentOwnerMayDispatchControllerEvents() {
        let coordinator = ControllerInputOwnershipCoordinator()
        let firstBoard = OwnerToken()
        let secondBoard = OwnerToken()

        coordinator.claim(firstBoard)
        #expect(coordinator.canDispatch(for: firstBoard))
        #expect(!coordinator.canDispatch(for: secondBoard))

        coordinator.claim(secondBoard)
        #expect(!coordinator.canDispatch(for: firstBoard))
        #expect(coordinator.canDispatch(for: secondBoard))

        coordinator.release(firstBoard)
        #expect(coordinator.canDispatch(for: secondBoard))

        coordinator.release(secondBoard)
        #expect(!coordinator.canDispatch(for: firstBoard))
        #expect(!coordinator.canDispatch(for: secondBoard))
    }
}
