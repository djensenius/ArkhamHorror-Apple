import SwiftUI

/// A view modifier that observes hardware keyboard events via SwiftUI's
/// native `onKeyPress(phases:action:)` and forwards them through
/// ``SemanticInputRouter``. Available on every platform target — `onKeyPress`
/// itself is universally available across iOS, iPadOS, macOS, tvOS, and
/// visionOS — and a harmless no-op wherever no hardware keyboard is attached.
struct SemanticKeyboardInput: ViewModifier {
    var table: InputMappingTable = .defaultKeyboard
    let onOutcome: (SemanticDispatchOutcome) -> Bool

    func body(content: Content) -> some View {
        content
            .onKeyPress(phases: [.down, .repeat, .up]) { keyPress in
                guard let control = KeyboardControl(keyPress.key) else { return .ignored }
                let phase = InputPhase(keyPress.phase)
                guard
                    let outcome = SemanticInputRouter.route(
                        PhysicalInputEvent(input: .keyboard(control), phase: phase), using: table
                    )
                else {
                    return .ignored
                }
                return onOutcome(outcome) ? .handled : .ignored
            }
    }
}

extension InputPhase {
    /// Maps SwiftUI's `KeyPress.Phases` option set to ``InputPhase``. `.down`
    /// takes priority over `.repeat`/`.up` since a single `KeyPress` never
    /// actually reports more than one phase bit set in practice, but the
    /// option-set type cannot itself guarantee that.
    init(_ phases: KeyPress.Phases) {
        if phases.contains(.down) {
            self = .press
        } else if phases.contains(.repeat) {
            self = .repeatPress
        } else {
            self = .release
        }
    }
}

extension KeyboardControl {
    /// The closed key-to-control mapping backing ``init(_:)``, factored into a
    /// dictionary (rather than a `switch`) purely to keep that initializer's
    /// cyclomatic complexity low; the mapping itself is unchanged.
    private static let keyMapping: [KeyEquivalent: KeyboardControl] = [
        .upArrow: .arrowUp, .downArrow: .arrowDown,
        .leftArrow: .arrowLeft, .rightArrow: .arrowRight,
        .space: .space, .return: .enter, .tab: .tab, .escape: .escape,
        "i": .letterI, "h": .letterH, "p": .letterP, "v": .letterV, "l": .letterL, "m": .letterM,
        "n": .letterN, "b": .letterB, "z": .letterZ, "a": .letterA,
        "[": .leftBracket, "]": .rightBracket, "=": .equals, "-": .minus,
    ]

    /// Maps a SwiftUI `KeyEquivalent` to the closed ``KeyboardControl``
    /// vocabulary. Any key not listed here (there is no default branch that
    /// guesses) safely returns `nil`, leaving the underlying key press
    /// `.ignored` for whatever responder would otherwise have handled it.
    init?(_ key: KeyEquivalent) {
        guard let control = Self.keyMapping[key] else { return nil }
        self = control
    }
}

public extension View {
    /// Applies ``SemanticKeyboardInput`` to this view. `onOutcome` returns
    /// whether it actually consumed the outcome: returning `false` (for
    /// example for ``SemanticDispatchOutcome/reservedBack`` when nothing is
    /// currently presented to dismiss) reports the key press itself as
    /// `.ignored`, letting it fall through to whatever other responder
    /// would otherwise handle Escape/Menu-style system behavior, rather
    /// than always swallowing it. See `SemanticInputHarnessView` for a
    /// usage example.
    func semanticKeyboardInput(
        table: InputMappingTable = .defaultKeyboard,
        onOutcome: @escaping (SemanticDispatchOutcome) -> Bool
    ) -> some View {
        modifier(SemanticKeyboardInput(table: table, onOutcome: onOutcome))
    }
}
