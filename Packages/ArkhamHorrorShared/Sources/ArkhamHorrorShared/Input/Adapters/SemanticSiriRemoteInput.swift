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
    struct SemanticSiriRemoteInput: ViewModifier {
        var table: InputMappingTable = .defaultSiriRemote
        let onOutcome: (SemanticDispatchOutcome) -> Void

        func body(content: Content) -> some View {
            content
                .onMoveCommand { direction in
                    guard let control = SiriRemoteControl(direction) else { return }
                    route(.siriRemote(control))
                }
                .onExitCommand {
                    // The Menu button is reserved regardless of `table`; see
                    // ``PhysicalInput/isReserved``.
                    route(.siriRemote(.menu))
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

    extension View {
        /// Applies ``SemanticSiriRemoteInput`` to this view (tvOS only).
        func semanticSiriRemoteInput(
            table: InputMappingTable = .defaultSiriRemote,
            onOutcome: @escaping (SemanticDispatchOutcome) -> Void
        ) -> some View {
            modifier(SemanticSiriRemoteInput(table: table, onOutcome: onOutcome))
        }
    }
#endif
