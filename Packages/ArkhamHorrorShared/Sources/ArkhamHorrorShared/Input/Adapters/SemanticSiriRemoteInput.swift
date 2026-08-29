#if os(tvOS)
    import SwiftUI

    /// A view modifier that observes the tvOS focus engine's move/exit
    /// commands — how the Siri Remote's swipe surface and Menu button reach
    /// SwiftUI — and forwards them through ``SemanticInputRouter``.
    ///
    /// `onMoveCommand`/`onExitCommand` are macOS/tvOS-only SwiftUI APIs; they
    /// are deliberately not used for the keyboard adapter's arrow keys (which
    /// use `onKeyPress` instead) to avoid two adapters racing to handle the
    /// same physical arrow-key event on macOS. This modifier is scoped to
    /// tvOS only for exactly that reason.
    ///
    /// `onExitCommand`'s callback is `Void`-returning: once installed, this
    /// view becomes unconditionally responsible for the Menu button, and
    /// there is no way to report "unhandled" back to tvOS so its own default
    /// behavior (typically returning to the Home Screen) can run instead.
    /// `canHandleBack` exists so a host can make that decision *before*
    /// installing the modifier at all: `.onExitCommand` is only attached
    /// while `canHandleBack()` is true (there is something this host can
    /// actually dismiss/navigate back out of); the moment nothing is
    /// presented, the modifier is entirely absent from the view tree and
    /// tvOS's own system default runs unimpeded. There is deliberately no
    /// default value for this parameter, so every call site is forced to
    /// consider it rather than silently reserving Menu forever.
    struct SemanticSiriRemoteInput: ViewModifier {
        var table: InputMappingTable = .defaultSiriRemote
        let canHandleBack: () -> Bool
        let onOutcome: (SemanticDispatchOutcome) -> Void

        func body(content: Content) -> some View {
            if canHandleBack() {
                content
                    .onMoveCommand { direction in
                        guard let control = SiriRemoteControl(direction) else { return }
                        route(.siriRemote(control))
                    }
                    .onExitCommand {
                        // The Menu button is reserved regardless of
                        // `table`; see ``PhysicalInput/isReserved``.
                        route(.siriRemote(.menu))
                    }
            } else {
                // No `.onExitCommand` attached at all: tvOS's own
                // default Menu behavior (e.g. returning to the Home
                // Screen) is free to run. Swipe navigation is still
                // wired, since move commands never swallow a system
                // default the way `.onExitCommand` does.
                content
                    .onMoveCommand { direction in
                        guard let control = SiriRemoteControl(direction) else { return }
                        route(.siriRemote(control))
                    }
            }
        }

        private func route(_ input: PhysicalInput) {
            guard
                let outcome = SemanticInputRouter.route(
                    PhysicalInputEvent(input: input, phase: .press), using: table
                )
            else { return }
            onOutcome(outcome)
        }
    }

    extension SiriRemoteControl {
        /// Fails for any `MoveCommandDirection` this vocabulary does not
        /// recognize, so an unrecognized direction is safely ignored rather
        /// than guessing a focus move — preserving the "unknown input is
        /// safely ignored" invariant.
        init?(_ direction: MoveCommandDirection) {
            switch direction {
            case .up: self = .swipeUp
            case .down: self = .swipeDown
            case .left: self = .swipeLeft
            case .right: self = .swipeRight
            @unknown default: return nil
            }
        }
    }

    public extension View {
        /// Applies ``SemanticSiriRemoteInput`` to this view (tvOS only).
        ///
        /// - Parameter canHandleBack: Whether the Menu button currently has
        ///   something to dismiss/navigate back out of. Evaluated on every
        ///   body re-render; `.onExitCommand` is only installed while this
        ///   returns `true`, so tvOS's own default Menu behavior can run
        ///   whenever it returns `false`.
        func semanticSiriRemoteInput(
            table: InputMappingTable = .defaultSiriRemote,
            canHandleBack: @escaping () -> Bool,
            onOutcome: @escaping (SemanticDispatchOutcome) -> Void
        ) -> some View {
            modifier(
                SemanticSiriRemoteInput(
                    table: table, canHandleBack: canHandleBack, onOutcome: onOutcome
                )
            )
        }
    }
#endif
