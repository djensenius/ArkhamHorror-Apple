import Foundation

/// The phase of one physical input event, mirroring SwiftUI's own
/// `KeyPress.Phases` (down/repeat/up) so the keyboard adapter can forward
/// events without inventing a parallel vocabulary; controller/Siri Remote
/// adapters use ``press``/``release`` only, since neither GameController nor
/// the tvOS focus engine produces a native "repeat" for a held button.
public enum InputPhase: Hashable, Sendable {
    case press
    case repeatPress
    case release
}

/// One physical control's event at a point in time, the sole input to
/// ``SemanticInputRouter/route(_:using:)``.
public struct PhysicalInputEvent: Hashable, Sendable {
    public let input: PhysicalInput
    public let phase: InputPhase

    public init(input: PhysicalInput, phase: InputPhase) {
        self.input = input
        self.phase = phase
    }
}

/// What a routed input event should cause: either a semantic command, or
/// (for a reserved control) the system back/menu/escape action, which is
/// deliberately not itself a ``SemanticCommand`` — see
/// ``PhysicalInput/isReserved``.
public enum SemanticDispatchOutcome: Hashable, Sendable {
    case command(SemanticCommand)
    case reservedBack
}

/// Pure translation from one physical input event to, at most, one dispatch
/// outcome.
///
/// - A reserved control (``PhysicalInput/isReserved``) always resolves to
///   ``SemanticDispatchOutcome/reservedBack`` on press/repeat, regardless of
///   any mapping table, so system back/menu/escape can never be remapped away.
/// - `.release` never dispatches anything: a button/key up carries no
///   semantic meaning in this vocabulary.
/// - `.repeatPress` only dispatches when the bound command is
///   ``SemanticCommand/isRepeatable``, so holding a key/button down cannot
///   fire a discrete action or toggle more than once.
/// - An input with no binding in `table` (including one this layer has never
///   heard of) safely produces `nil` — never a guessed or default command.
public enum SemanticInputRouter {
    public static func route(
        _ event: PhysicalInputEvent, using table: InputMappingTable
    ) -> SemanticDispatchOutcome? {
        guard event.phase != .release else { return nil }
        if event.input.isReserved {
            return .reservedBack
        }
        guard let command = table.command(for: event.input) else { return nil }
        if event.phase == .repeatPress, !command.isRepeatable {
            return nil
        }
        return .command(command)
    }
}
