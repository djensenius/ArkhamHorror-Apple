import SwiftUI

#if canImport(GameController) && !os(tvOS)
    final class BoardControllerInputOwner {}

    enum BoardControllerInputSceneOwnership {
        @MainActor
        static func scenePhaseDidChange(
            _ phase: ScenePhase,
            owner: BoardControllerInputOwner,
            coordinator: ControllerInputOwnershipCoordinator = .shared
        ) {
            guard phase == .active else { return }
            coordinator.claim(owner)
        }
    }

    enum BoardControllerInputDispatchGate {
        @MainActor
        @discardableResult
        static func dispatch(
            _ outcome: SemanticDispatchOutcome,
            owner: BoardControllerInputOwner,
            coordinator: ControllerInputOwnershipCoordinator = .shared,
            handler: (SemanticDispatchOutcome) -> Void
        ) -> Bool {
            guard coordinator.canDispatch(for: owner) else { return false }
            handler(outcome)
            return true
        }
    }
#endif

extension BoardView {
    func updateControllerInputs(_ controller: BoardCommandController) {
        controller.updateChoiceHandler(onChoice)
        controller.updateAmountsHandler(onAmounts)
        controller.updatePaymentAmountsHandler(onPaymentAmounts)
        controller.updateExchangeAmountHandler(onExchangeAmount)
        controller.updateRetryHandler(onRetryChoice)
        controller.updateCatalogRetryHandler(onCatalogRetry)
        controller.updateLocalPlayerID(localPlayerID)
        controller.updateCardCatalog(cardCatalog)
    }

    #if canImport(GameController) && !os(tvOS)
        func startControllerInputIfAvailable(for controller: BoardCommandController) {
            ControllerInputOwnershipCoordinator.shared.claim(controllerInputOwner)
            if let controllerInputCenter {
                controllerInputCenter.start()
                return
            }
            let owner = controllerInputOwner
            let center = ControllerInputCenter(discovery: GameControllerDiscovery()) { outcome in
                BoardControllerInputDispatchGate.dispatch(outcome, owner: owner) {
                    controller.handle($0)
                }
            }
            controllerInputCenter = center
            center.start()
        }

        func stopControllerInputIfAvailable() {
            ControllerInputOwnershipCoordinator.shared.release(controllerInputOwner)
            controllerInputCenter?.stop()
        }

        func controllerInputScenePhaseDidChange(_ phase: ScenePhase) {
            BoardControllerInputSceneOwnership.scenePhaseDidChange(
                phase,
                owner: controllerInputOwner
            )
        }
    #else
        func startControllerInputIfAvailable(for _: BoardCommandController) {}
        func stopControllerInputIfAvailable() {}
        func controllerInputScenePhaseDidChange(_: ScenePhase) {}
    #endif
}
