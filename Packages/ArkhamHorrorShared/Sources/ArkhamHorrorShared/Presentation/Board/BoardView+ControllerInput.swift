import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

#if canImport(GameController) && !os(tvOS)
    final class BoardControllerInputOwner {}

    enum BoardControllerInputOwnershipDecision: Equatable {
        case claim
        case release
        case none
    }

    struct BoardControllerInputOwnershipState: Equatable {
        var started: Bool
        var isKey: Bool
        var scenePhase: ScenePhase

        var decision: BoardControllerInputOwnershipDecision {
            guard started else { return .release }
            guard scenePhase != .background else { return .release }
            guard scenePhase == .active, isKey else { return .none }
            return .claim
        }
    }

    enum BoardControllerInputOwnershipPolicy {
        @MainActor
        static func apply(
            _ state: BoardControllerInputOwnershipState,
            owner: BoardControllerInputOwner,
            coordinator: ControllerInputOwnershipCoordinator = .shared
        ) {
            switch state.decision {
            case .claim:
                coordinator.claim(owner)
            case .release:
                coordinator.release(owner)
            case .none:
                break
            }
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

#if (os(iOS) || os(visionOS)) && canImport(UIKit) && canImport(GameController)
    struct BoardControllerInputWindowKeyObserver: UIViewRepresentable {
        var onChange: @MainActor (Bool) -> Void

        func makeUIView(context _: Context) -> WindowKeyObservingView {
            WindowKeyObservingView(onChange: onChange)
        }

        func updateUIView(_ uiView: WindowKeyObservingView, context _: Context) {
            uiView.onChange = onChange
            uiView.publishCurrentKeyState()
        }

        final class WindowKeyObservingView: UIView {
            var onChange: @MainActor (Bool) -> Void
            private weak var observedWindow: UIWindow?
            private var becameKeyToken: NSObjectProtocol?
            private var resignedKeyToken: NSObjectProtocol?

            init(onChange: @escaping @MainActor (Bool) -> Void) {
                self.onChange = onChange
                super.init(frame: .zero)
                isHidden = true
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                nil
            }

            deinit {
                removeWindowObservers()
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                observe(window)
            }

            func publishCurrentKeyState() {
                onChange(observedWindow?.isKeyWindow == true)
            }

            private func observe(_ window: UIWindow?) {
                guard observedWindow !== window else {
                    publishCurrentKeyState()
                    return
                }
                removeWindowObservers()
                observedWindow = window
                publishCurrentKeyState()

                guard let window else { return }
                let center = NotificationCenter.default
                becameKeyToken = center.addObserver(
                    forName: UIWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onChange(true)
                }
                resignedKeyToken = center.addObserver(
                    forName: UIWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onChange(false)
                }
            }

            private func removeWindowObservers() {
                let center = NotificationCenter.default
                if let becameKeyToken {
                    center.removeObserver(becameKeyToken)
                }
                if let resignedKeyToken {
                    center.removeObserver(resignedKeyToken)
                }
                becameKeyToken = nil
                resignedKeyToken = nil
            }
        }
    }
#endif

#if canImport(GameController) && !os(tvOS)
    private struct BoardControllerInputWindowFocusModifier: ViewModifier {
        let scenePhase: ScenePhase
        let onChange: @MainActor (Bool, ScenePhase) -> Void

        #if os(macOS)
            @Environment(\.controlActiveState) private var controlActiveState
        #endif

        func body(content: Content) -> some View {
            #if os(macOS)
                content
                    .onAppear {
                        onChange(controlActiveState == .key, scenePhase)
                    }
                    .onChange(of: controlActiveState) { _, newValue in
                        onChange(newValue == .key, scenePhase)
                    }
            #elseif os(iOS) || os(visionOS)
                content
                    .background {
                        BoardControllerInputWindowKeyObserver { isKey in
                            onChange(isKey, scenePhase)
                        }
                    }
            #else
                content
            #endif
        }
    }

    extension View {
        func boardControllerInputWindowFocusObserver(
            scenePhase: ScenePhase,
            onChange: @escaping @MainActor (Bool, ScenePhase) -> Void
        ) -> some View {
            modifier(BoardControllerInputWindowFocusModifier(
                scenePhase: scenePhase,
                onChange: onChange
            ))
        }
    }
#else
    extension View {
        func boardControllerInputWindowFocusObserver(
            scenePhase _: ScenePhase,
            onChange _: @escaping @MainActor (Bool, ScenePhase) -> Void
        ) -> some View {
            self
        }
    }
#endif

extension BoardView {
    func updateControllerInputs(_ controller: BoardCommandController) {
        controller.updateChoiceHandler(onChoice)
        controller.updateAmountsHandler(onAmounts)
        controller.updatePaymentAmountsHandler(onPaymentAmounts)
        controller.updateExchangeAmountHandler(onExchangeAmount)
        controller.updatePickDestinyHandler(onPickDestiny)
        controller.updateRetryHandler(onRetryChoice)
        controller.updateCatalogRetryHandler(onCatalogRetry)
        controller.updateLocalPlayerID(localPlayerID)
        controller.updateIsSolo(isSolo)
        controller.updateIsLocalSpectator(isLocalSpectator)
        controller.updateCardCatalog(cardCatalog)
    }

    #if canImport(GameController) && !os(tvOS)
        func startControllerInputIfAvailable(
            for controller: BoardCommandController, scenePhase: ScenePhase, isKey: Bool
        ) {
            controllerInputStarted = true
            controllerInputWindowIsKey = isKey
            if let controllerInputCenter {
                controllerInputCenter.start()
                applyControllerInputOwnership(scenePhase: scenePhase)
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
            applyControllerInputOwnership(scenePhase: scenePhase)
        }

        func stopControllerInputIfAvailable() {
            controllerInputStarted = false
            applyControllerInputOwnership(scenePhase: .background)
            controllerInputCenter?.stop()
        }

        func controllerInputScenePhaseDidChange(_ phase: ScenePhase) {
            applyControllerInputOwnership(scenePhase: phase)
        }

        func controllerInputWindowFocusDidChange(_ isKey: Bool, scenePhase: ScenePhase) {
            controllerInputWindowIsKey = isKey
            applyControllerInputOwnership(scenePhase: scenePhase)
        }

        private func applyControllerInputOwnership(scenePhase: ScenePhase) {
            BoardControllerInputOwnershipPolicy.apply(
                BoardControllerInputOwnershipState(
                    started: controllerInputStarted,
                    isKey: controllerInputWindowIsKey,
                    scenePhase: scenePhase
                ),
                owner: controllerInputOwner
            )
        }
    #else
        func startControllerInputIfAvailable(
            for _: BoardCommandController, scenePhase _: ScenePhase, isKey _: Bool
        ) {}
        func stopControllerInputIfAvailable() {}
        func controllerInputScenePhaseDidChange(_: ScenePhase) {}
        func controllerInputWindowFocusDidChange(_: Bool, scenePhase _: ScenePhase) {}
    #endif
}
