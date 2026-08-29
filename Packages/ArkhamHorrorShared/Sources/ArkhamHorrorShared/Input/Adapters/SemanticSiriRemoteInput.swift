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
    /// `onExitCommand(perform:)` takes an **optional** closure — passing
    /// `nil` is Apple's own documented equivalent of "this method was never
    /// called," letting tvOS's system default (typically returning to the
    /// Home Screen) run. `canHandleBack` decides, on every body re-render,
    /// which of the two to pass (via ``conditionalCommandClosure``): a real
    /// closure while there is something this host can actually dismiss/
    /// navigate back out of, `nil` the moment nothing is presented.
    /// Critically, this modifier is *always* applied to `content` (the same
    /// call, same argument type, every render) — only the argument *value*
    /// changes between a closure and `nil`, never whether the modifier
    /// itself is present. An earlier version of this modifier instead
    /// branched `content` itself inside an `if/else`
    /// (`content.onExitCommand { ... }` vs. plain `content`), which are
    /// *different concrete types* — SwiftUI's diffing algorithm cannot
    /// recognize the same underlying `content` across a type change at that
    /// tree position, so every `canHandleBack` toggle destroyed and rebuilt
    /// the *entire* wrapped subtree, resetting any `@FocusState`/
    /// `@GestureState` nested inside `content`. Passing `nil` instead keeps
    /// `content`'s wrapping type — and thus its identity — perfectly stable
    /// across every toggle. There is deliberately no default value for this
    /// parameter, so every call site is forced to consider it rather than
    /// silently reserving Menu forever.
    ///
    /// The default Siri Remote Play/Pause button is mapped (see
    /// ``InputMappingTable/defaultSiriRemote``) to
    /// ``SemanticCommand/toggleMenuSurface`` — this app has no media
    /// playback to preserve system Play/Pause semantics for, so (unlike
    /// Menu) Play/Pause is always claimed outright via `onPlayPauseCommand`,
    /// with no `canHandleBack`-style conditional.
    struct SemanticSiriRemoteInput: ViewModifier {
        var table: InputMappingTable = .defaultSiriRemote
        let canHandleBack: () -> Bool
        let onOutcome: (SemanticDispatchOutcome) -> Void

        func body(content: Content) -> some View {
            content
                .onMoveCommand { direction in
                    guard let control = SiriRemoteControl(direction) else { return }
                    route(.siriRemote(control))
                }
                .onExitCommand(
                    perform: conditionalCommandClosure(isEnabled: canHandleBack()) {
                        // The Menu button is reserved regardless of
                        // `table`; see ``PhysicalInput/isReserved``.
                        route(.siriRemote(.menu))
                    }
                )
                .onPlayPauseCommand {
                    route(.siriRemote(.playPause))
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
        ///   body re-render; while this returns `false`, `nil` is passed to
        ///   `.onExitCommand(perform:)` so tvOS's own default Menu behavior
        ///   can run — without ever conditionally attaching/detaching the
        ///   modifier itself, which would otherwise reset any
        ///   `@FocusState`/`@GestureState` nested in this view.
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
