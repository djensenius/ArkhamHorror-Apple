@testable import ArkhamHorrorShared
import SwiftUI
import Testing

#if canImport(GameController) && !os(tvOS)
    @MainActor
    @Suite("Controller input ownership")
    struct ControllerInputOwnershipCoordinatorTests {
        private final class OwnerToken {}

        @Test("Ownership policy decisions claim only started key active boards")
        func ownershipPolicyDecisionsClaimOnlyStartedKeyActiveBoards() {
            #expect(BoardControllerInputOwnershipState(
                started: false,
                isKey: true,
                scenePhase: .active
            ).decision == .none)
            #expect(BoardControllerInputOwnershipState(
                started: true,
                isKey: true,
                scenePhase: .background
            ).decision == .none)
            #expect(BoardControllerInputOwnershipState(
                started: true,
                isKey: false,
                scenePhase: .active
            ).decision == .none)
            #expect(BoardControllerInputOwnershipState(
                started: true,
                isKey: true,
                scenePhase: .inactive
            ).decision == .none)
            #expect(BoardControllerInputOwnershipState(
                started: true,
                isKey: true,
                scenePhase: .active
            ).decision == .claim)
        }

        @Test("Key window changes route controller input between simultaneously active boards")
        func keyWindowChangesRouteControllerInputBetweenSimultaneouslyActiveBoards() {
            let coordinator = ControllerInputOwnershipCoordinator()
            let firstBoard = BoardControllerInputOwner()
            let secondBoard = BoardControllerInputOwner()

            BoardControllerInputOwnershipPolicy.apply(
                BoardControllerInputOwnershipState(started: true, isKey: true, scenePhase: .active),
                owner: firstBoard,
                coordinator: coordinator
            )
            #expect(coordinator.canDispatch(for: firstBoard))
            #expect(!coordinator.canDispatch(for: secondBoard))

            BoardControllerInputOwnershipPolicy.apply(
                BoardControllerInputOwnershipState(started: true, isKey: true, scenePhase: .active),
                owner: secondBoard,
                coordinator: coordinator
            )
            #expect(!coordinator.canDispatch(for: firstBoard))
            #expect(coordinator.canDispatch(for: secondBoard))

            BoardControllerInputOwnershipPolicy.apply(
                BoardControllerInputOwnershipState(started: true, isKey: true, scenePhase: .active),
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

        @Test("Releasing the current input owner hands control back to a remaining board")
        func releasingCurrentInputOwnerHandsControlBackToRemainingBoard() {
            let coordinator = ControllerInputOwnershipCoordinator()
            let firstBoard = OwnerToken()
            let secondBoard = OwnerToken()

            coordinator.claim(firstBoard)
            coordinator.claim(secondBoard)
            #expect(!coordinator.canDispatch(for: firstBoard))
            #expect(coordinator.canDispatch(for: secondBoard))

            coordinator.release(secondBoard)
            #expect(coordinator.canDispatch(for: firstBoard))
            #expect(!coordinator.canDispatch(for: secondBoard))

            coordinator.release(firstBoard)
            #expect(!coordinator.canDispatch(for: firstBoard))
            #expect(!coordinator.canDispatch(for: secondBoard))
        }
    }
#endif
