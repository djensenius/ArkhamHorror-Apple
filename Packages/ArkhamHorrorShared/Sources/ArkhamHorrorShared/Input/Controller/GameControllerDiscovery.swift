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
    /// Idempotent, ownership-aware teardown: every `GCControllerButtonInput`
    /// this source binds goes through ``GCButtonEventMultiplexer``, the
    /// single process-level owner of each button's real
    /// `pressedChangedHandler` slot — this source only ever holds a
    /// subscription *token* for each button, never that slot directly, so
    /// two independently-live sources wrapping the same physical controller
    /// (for example across two overlapping ``GameControllerDiscovery``
    /// instances) can each subscribe without overwriting the other, and
    /// each source's own ``teardown()`` only ever unsubscribes its own
    /// tokens. This mirrors ``ControllerInputCenter``'s own
    /// `handlerOwner`-based protection at a different layer (protecting
    /// `onButtonEvent` itself, a property on this type's own
    /// ``ControllerInputSource`` conformance, not the real button object) —
    /// that layer is untouched here.
    @MainActor
    final class GCControllerSource: ControllerInputSource {
        private typealias BoundButton = (
            button: GCControllerButtonInput, token: GCButtonEventMultiplexer.Token
        )

        let id: ControllerID
        let snapshot: ControllerSnapshot
        var onButtonEvent: ((ControllerControl, InputPhase) -> Void)?
        var handlerOwner: ObjectIdentifier?
        private var boundButtons: [BoundButton] = []

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
            // still never leave a live, owned button subscription pointing
            // at a dead `[weak self]` closure.
            teardown()
        }

        /// Unsubscribes every button token this source still holds (via
        /// ``GCButtonEventMultiplexer``) and clears its own
        /// ``onButtonEvent``. Safe to call more than once, and safe from
        /// more than one call site (`deinit`,
        /// ``GameControllerDiscovery/unwrap(_:)``,
        /// ``GameControllerDiscovery/stop()``): each unsubscribes only its
        /// own tokens, so calling it twice is a harmless no-op, and it never
        /// affects any *other* source's independent subscription to the
        /// same button.
        func teardown() {
            onButtonEvent = nil
            let ownedButtons = boundButtons
            boundButtons.removeAll()
            for (button, token) in ownedButtons {
                GCButtonEventMultiplexer.shared.unsubscribe(token, from: button)
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
            let token = GCButtonEventMultiplexer.shared.subscribe(to: button) { [weak self] phase in
                self?.onButtonEvent?(control, phase)
            }
            boundButtons.append((button, token))
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
