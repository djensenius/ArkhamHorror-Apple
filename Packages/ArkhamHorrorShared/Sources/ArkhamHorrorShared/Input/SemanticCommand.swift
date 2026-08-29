import Foundation

/// A cardinal direction used by ``SemanticCommand/focusMove(_:)`` and by
/// ``FocusGraph`` adjacency. Deliberately four-way only: no diagonal or
/// analog-stick-angle cases exist, since every platform focus adapter
/// (keyboard arrows, Siri Remote swipes, controller d-pad) already collapses
/// its own input to one of these four values before it reaches this layer.
enum FocusDirection: Hashable, Sendable, CaseIterable {
    // swiftlint:disable:next identifier_name
    case up, down, left, right
}

/// The direction of a relative cycling command (``SemanticCommand/cyclePlayer(_:)``,
/// ``SemanticCommand/cycleZone(_:)``).
enum CycleDirection: Hashable, Sendable, CaseIterable {
    case next, previous
}

/// The direction of a relative camera rotation command
/// (``SemanticCommand/rotateCamera(_:)``).
enum RotationDirection: Hashable, Sendable, CaseIterable {
    case clockwise, counterclockwise
}

/// The closed vocabulary of gameplay/navigation commands every platform input
/// adapter (keyboard, Siri Remote, controller, pointer/touch, visionOS focus)
/// dispatches instead of emulating a mouse or manipulating tabletop objects
/// directly.
///
/// This is intentionally closed and rules-free: it names *what the player
/// asked for*, never *what happens next*. No case references a specific card,
/// investigator, or board coordinate, and no case implies a specific visual
/// affordance (there is no `.click(at:)`/`.drag(to:)`, and no virtual cursor
/// position is represented anywhere in this type). Interpreting a command
/// (for example, resolving `.primaryAction` against whatever is currently
/// focused) is entirely the presentation/game layer's responsibility, not
/// this type's.
///
/// System back/menu/escape behavior is deliberately **not** represented here:
/// see ``PhysicalInput/isReserved`` and ``SemanticDispatchOutcome/reservedBack``.
/// Reserved controls never produce a `SemanticCommand`, so no case in this
/// vocabulary can ever collide with, or be remapped to replace, the system
/// back gesture.
enum SemanticCommand: Hashable, Sendable {
    /// Moves focus one step in the semantic focus graph. See ``FocusGraph``.
    case focusMove(FocusDirection)
    /// The primary action for whatever is currently focused (for example,
    /// "play this card" or "confirm this choice").
    case primaryAction
    /// The secondary action for whatever is currently focused (for example,
    /// a context action or an alternate resolution).
    case secondaryAction
    /// Requests a closer, read-only look at whatever is currently focused.
    case inspect
    /// Toggles the investigator's hand surface.
    case toggleHandSurface
    /// Toggles the active prompt/question surface.
    case togglePromptSurface
    /// Toggles the investigator sheet/status surface.
    case toggleInvestigatorSurface
    /// Toggles the campaign/game log surface.
    case toggleLogSurface
    /// Toggles the menu surface.
    case toggleMenuSurface
    /// Cycles which player's board/surfaces are focused.
    case cyclePlayer(CycleDirection)
    /// Cycles which zone (play area, hand, threat area, and so on) is focused.
    case cycleZone(CycleDirection)
    /// Jumps focus directly to whatever currently holds an active prompt.
    case jumpToActivePrompt
    /// Increases camera zoom.
    case zoomIn
    /// Decreases camera zoom.
    case zoomOut
    /// Rotates the camera around the board.
    case rotateCamera(RotationDirection)
    /// Resets the camera to its default position, zoom, and rotation.
    case resetCamera
    /// Confirms the current multiselect choice.
    case confirmMultiselect
    /// Cancels the current multiselect choice.
    case cancelMultiselect
    /// Undoes the most recent reversible action.
    case undo
    /// Toggles explicit arrange mode (deliberate, player-initiated
    /// rearrangement of a zone's contents; never entered implicitly by a
    /// drag or pointer gesture).
    case toggleArrangeMode

    /// Every case in the closed vocabulary, expanding associated-value cases
    /// over their own `CaseIterable` payload. Used by tests to assert
    /// mapping-table and router coverage against the full vocabulary rather
    /// than an incomplete hand-picked subset.
    static var allCases: [SemanticCommand] {
        FocusDirection.allCases.map(SemanticCommand.focusMove)
            + [
                .primaryAction, .secondaryAction, .inspect,
                .toggleHandSurface, .togglePromptSurface, .toggleInvestigatorSurface,
                .toggleLogSurface, .toggleMenuSurface,
            ]
            + CycleDirection.allCases.map(SemanticCommand.cyclePlayer)
            + CycleDirection.allCases.map(SemanticCommand.cycleZone)
            + [.jumpToActivePrompt, .zoomIn, .zoomOut]
            + RotationDirection.allCases.map(SemanticCommand.rotateCamera)
            + [
                .resetCamera, .confirmMultiselect, .cancelMultiselect, .undo,
                .toggleArrangeMode,
            ]
    }

    /// Whether a physical control bound to this command may repeat-fire while
    /// held (see ``SemanticInputRouter``). Continuous/relative adjustments
    /// (focus movement, zoom, rotation, cycling) are repeatable; discrete
    /// actions and toggles are not, so holding a key or button down cannot,
    /// for example, silently fire `.primaryAction` or `.toggleArrangeMode`
    /// more than once.
    var isRepeatable: Bool {
        switch self {
        case .focusMove, .zoomIn, .zoomOut, .rotateCamera, .cyclePlayer, .cycleZone:
            true
        default:
            false
        }
    }
}
