#if canImport(GameController) && !os(tvOS)
    final class BoardControllerInputOwner {}
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
                guard ControllerInputOwnershipCoordinator.shared.canDispatch(for: owner) else {
                    return
                }
                controller.handle(outcome)
            }
            controllerInputCenter = center
            center.start()
        }

        func stopControllerInputIfAvailable() {
            ControllerInputOwnershipCoordinator.shared.release(controllerInputOwner)
            controllerInputCenter?.stop()
        }
    #else
        func startControllerInputIfAvailable(for _: BoardCommandController) {}
        func stopControllerInputIfAvailable() {}
    #endif
}
