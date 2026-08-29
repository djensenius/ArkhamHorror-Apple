#if canImport(GameController)
    @preconcurrency import Foundation
    @preconcurrency import GameController

    /// Production ``ControllerDiscovering`` backed by the real GameController
    /// framework. Available on every platform target (iOS, macOS, tvOS, and
    /// visionOS all ship GameController); the `canImport` guard exists purely
    /// as defence-in-depth against a future target that does not.
    ///
    /// GameController delivers connect/disconnect notifications via
    /// `NotificationCenter` (this adapter explicitly requests `queue: .main`
    /// for both observers below), and button-press handlers via each
    /// `GCController`'s own `handlerQueue`, which defaults to the main queue;
    /// this type never reassigns it, so every callback below is expected to
    /// already be main-actor-isolated in practice. Rather than asserting that
    /// with ``MainActor.assumeIsolated`` (which would trap if that assumption
    /// is ever violated, e.g. by a future refactor changing `handlerQueue`),
    /// every callback explicitly hops to the main actor via
    /// `Task { @MainActor in ... }`, which is safe regardless of the calling
    /// context and keeps actor isolation sound under Swift 6.
    @MainActor
    public final class GameControllerDiscovery: ControllerDiscovering {
        private var onConnect: ((any ControllerInputSource) -> Void)?
        private var onDisconnect: ((ControllerID) -> Void)?
        private var connectToken: NSObjectProtocol?
        private var disconnectToken: NSObjectProtocol?
        private var sources: [ControllerID: GCControllerSource] = [:]
        /// Guards against a connect/disconnect notification whose handler
        /// already started (and hopped to the main actor via `Task`) before
        /// ``stop()`` ran: without this check, that in-flight `Task` could
        /// still call ``wrap(_:)``/``unwrap(_:)`` after teardown, silently
        /// re-registering a source this discovery no longer owns.
        private var isActive = false

        public init() {}

        public func start(
            onConnect: @escaping (any ControllerInputSource) -> Void,
            onDisconnect: @escaping (ControllerID) -> Void
        ) {
            stop()
            isActive = true
            self.onConnect = onConnect
            self.onDisconnect = onDisconnect
            connectToken = NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect, object: nil, queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.wrap(controller)
                }
            }
            disconnectToken = NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect, object: nil, queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.unwrap(controller)
                }
            }
            for controller in GCController.controllers() {
                wrap(controller)
            }
        }

        public func stop() {
            isActive = false
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
                source.teardown()
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
            sources[id]?.teardown()
            sources[id] = nil
            onDisconnect?(id)
        }
    }

    /// Wraps one connected `GCController`'s extended gamepad profile,
    /// translating its button events into ``ControllerControl``/``InputPhase``
    /// pairs. A controller with no extended gamepad profile reports
    /// ``ControllerProfileKind/unsupported`` and never calls
    /// ``onButtonEvent``.
    ///
    /// Idempotent, ownership-aware teardown: each `GCControllerButtonInput`
    /// this source binds is a real, OS-owned object shared by every wrapper
    /// that has ever bound it (`pressedChangedHandler` is a single-slot
    /// property on the button itself, not on this source) — a stale, since-
    /// superseded source that still calls ``teardown()`` (from
    /// ``GameControllerDiscovery/stop()``, ``GameControllerDiscovery/unwrap(_:)``,
    /// or its own `deinit`) must never clear a *newer* source's live
    /// registration on the same button. ``buttonOwners`` records, per button,
    /// which source instance most recently bound it, so ``teardown()`` only
    /// clears a button's handler while this source is still its recorded
    /// owner. This mirrors ``ControllerInputCenter``'s own
    /// `handlerOwner`-based protection at the button level, where the shared
    /// object is a real `GCControllerButtonInput` rather than a
    /// ``ControllerInputSource``.
    @MainActor
    final class GCControllerSource: ControllerInputSource {
        /// Keyed by `ObjectIdentifier` of the real, OS-owned button object,
        /// not by anything belonging to this type — so it correctly tracks
        /// ownership even across multiple `GCControllerSource` instances
        /// that end up (transiently) wrapping the same physical controller.
        private static var buttonOwners: [ObjectIdentifier: ObjectIdentifier] = [:]

        let id: ControllerID
        let snapshot: ControllerSnapshot
        var onButtonEvent: ((ControllerControl, InputPhase) -> Void)?
        var handlerOwner: ObjectIdentifier?
        private var boundButtons: [GCControllerButtonInput] = []

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

        isolated deinit {
            // Mirrors `ControllerInputCenter`'s own `isolated deinit`
            // safety net (SE-0371): a caller that drops this source without
            // ever calling `teardown()` explicitly (for example a discarded
            // duplicate from a re-evaluated `@State` initial value) must
            // still never leave a live, owned button handler pointing at a
            // dead `[weak self]` closure.
            teardown()
        }

        /// Clears every button handler this source still owns (per
        /// ``buttonOwners``) and its own ``onButtonEvent``. Safe to call more
        /// than once, and safe from more than one call site (`deinit`,
        /// ``GameControllerDiscovery/unwrap(_:)``,
        /// ``GameControllerDiscovery/stop()``); each clears only what it
        /// still owns, so calling it twice — or calling it on a source that
        /// has already been superseded by a newer one on the same button —
        /// is always a harmless no-op for anything it no longer owns.
        func teardown() {
            onButtonEvent = nil
            let ownedButtons = boundButtons
            boundButtons.removeAll()
            for button in ownedButtons {
                let key = ObjectIdentifier(button)
                guard Self.buttonOwners[key] == ObjectIdentifier(self) else { continue }
                button.pressedChangedHandler = nil
                Self.buttonOwners[key] = nil
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
            guard let button else { return }
            Self.buttonOwners[ObjectIdentifier(button)] = ObjectIdentifier(self)
            boundButtons.append(button)
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                Task { @MainActor in
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
