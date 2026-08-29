#if canImport(GameController)
    @preconcurrency import Foundation
    @preconcurrency import GameController

    /// Production ``ControllerDiscovering`` backed by the real GameController
    /// framework. Available on every platform target (iOS, macOS, tvOS, and
    /// visionOS all ship GameController); the `canImport` guard exists purely
    /// as defence-in-depth against a future target that does not.
    ///
    /// GameController delivers connect/disconnect notifications and button
    /// handlers on `GCController.current`'s `handlerQueue`, which defaults to
    /// the main queue; this type never reassigns it, so every callback below
    /// is already effectively main-actor-isolated in practice.
    /// ``MainActor.assumeIsolated`` documents and enforces that assumption at
    /// the one point (``GCControllerSource``) it is actually relied upon.
    @MainActor
    final class GameControllerDiscovery: ControllerDiscovering {
        private var onConnect: ((any ControllerInputSource) -> Void)?
        private var onDisconnect: ((ControllerID) -> Void)?
        private var connectToken: NSObjectProtocol?
        private var disconnectToken: NSObjectProtocol?
        private var sources: [ControllerID: GCControllerSource] = [:]

        func start(
            onConnect: @escaping (any ControllerInputSource) -> Void,
            onDisconnect: @escaping (ControllerID) -> Void
        ) {
            stop()
            self.onConnect = onConnect
            self.onDisconnect = onDisconnect
            connectToken = NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect, object: nil, queue: .main
            ) { [weak self] notification in
                // `queue: .main` guarantees this runs on the main thread; this
                // adapter never reassigns that, so the assumption is safe.
                guard let controller = notification.object as? GCController else { return }
                MainActor.assumeIsolated {
                    self?.wrap(controller)
                }
            }
            disconnectToken = NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect, object: nil, queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                MainActor.assumeIsolated {
                    self?.unwrap(controller)
                }
            }
            for controller in GCController.controllers() {
                wrap(controller)
            }
        }

        func stop() {
            if let connectToken {
                NotificationCenter.default.removeObserver(connectToken)
            }
            if let disconnectToken {
                NotificationCenter.default.removeObserver(disconnectToken)
            }
            connectToken = nil
            disconnectToken = nil
            onConnect = nil
            onDisconnect = nil
            for (_, source) in sources {
                source.onButtonEvent = nil
            }
            sources.removeAll()
        }

        private func wrap(_ controller: GCController) {
            let id = ControllerID(objectID: ObjectIdentifier(controller))
            guard sources[id] == nil else { return }
            let source = GCControllerSource(controller: controller, id: id)
            sources[id] = source
            onConnect?(source)
        }

        private func unwrap(_ controller: GCController) {
            let id = ControllerID(objectID: ObjectIdentifier(controller))
            sources[id]?.onButtonEvent = nil
            sources[id] = nil
            onDisconnect?(id)
        }
    }

    /// Wraps one connected `GCController`'s extended gamepad profile,
    /// translating its button events into ``ControllerControl``/``InputPhase``
    /// pairs. A controller with no extended gamepad profile reports
    /// ``ControllerProfileKind/unsupported`` and never calls
    /// ``onButtonEvent``.
    @MainActor
    final class GCControllerSource: ControllerInputSource {
        let id: ControllerID
        let snapshot: ControllerSnapshot
        var onButtonEvent: ((ControllerControl, InputPhase) -> Void)?

        init(controller: GCController, id: ControllerID) {
            self.id = id
            let glyph = ControllerGlyphFamily(productCategory: controller.productCategory)
            if let gamepad = controller.extendedGamepad {
                snapshot = ControllerSnapshot(
                    id: id, profile: .extendedGamepad, glyphFamily: glyph,
                    vendorName: controller.vendorName
                )
                installHandlers(on: gamepad)
            } else {
                snapshot = ControllerSnapshot(
                    id: id, profile: .unsupported, glyphFamily: glyph,
                    vendorName: controller.vendorName
                )
            }
        }

        private func installHandlers(on gamepad: GCExtendedGamepad) {
            bind(gamepad.dpad.up, to: .dpadUp)
            bind(gamepad.dpad.down, to: .dpadDown)
            bind(gamepad.dpad.left, to: .dpadLeft)
            bind(gamepad.dpad.right, to: .dpadRight)
            bind(gamepad.buttonA, to: .buttonA)
            bind(gamepad.buttonB, to: .buttonB)
            bind(gamepad.buttonX, to: .buttonX)
            bind(gamepad.buttonY, to: .buttonY)
            bind(gamepad.leftShoulder, to: .leftShoulder)
            bind(gamepad.rightShoulder, to: .rightShoulder)
            bind(gamepad.leftTrigger, to: .leftTrigger)
            bind(gamepad.rightTrigger, to: .rightTrigger)
            bind(gamepad.leftThumbstickButton, to: .leftThumbstickButton)
            bind(gamepad.rightThumbstickButton, to: .rightThumbstickButton)
            bind(gamepad.buttonMenu, to: .buttonMenu)
            bind(gamepad.buttonOptions, to: .buttonOptions)
            bind(gamepad.buttonHome, to: .buttonHome)
        }

        private func bind(_ button: GCControllerButtonInput?, to control: ControllerControl) {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    self?.onButtonEvent?(control, pressed ? .press : .release)
                }
            }
        }
    }

    private extension ControllerGlyphFamily {
        init(productCategory: String) {
            switch productCategory {
            case GCProductCategoryXboxOne:
                self = .xbox
            case GCProductCategoryDualSense, GCProductCategoryDualShock4:
                self = .playStation
            case GCProductCategoryMFi:
                self = .mfi
            default:
                self = .unknown
            }
        }
    }
#endif
