import Foundation

/// The closed set of keyboard controls the input layer recognizes. Any other
/// physical key is inspectable at the OS level but never reaches
/// ``PhysicalInput``, so it can never accidentally dispatch a command.
public enum KeyboardControl: Hashable, Sendable, CaseIterable {
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case space, enter, tab
    /// Reserved: always resolves to ``SemanticDispatchOutcome/reservedBack``.
    /// See ``PhysicalInput/isReserved``.
    case escape
    case letterI, letterH, letterP, letterV, letterL, letterM, letterN, letterB, letterZ, letterA
    case leftBracket, rightBracket, equals, minus
}

/// The closed set of extended-gamepad controls (Xbox/PlayStation/MFi all
/// expose the same abstract shape via `GCExtendedGamepad`; only glyphs
/// differ). See ``ControllerGlyphFamily``.
public enum ControllerControl: Hashable, Sendable, CaseIterable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case buttonOptions
    /// Reserved: always resolves to ``SemanticDispatchOutcome/reservedBack``.
    case buttonMenu
    /// Reserved: always resolves to ``SemanticDispatchOutcome/reservedBack``.
    case buttonHome
}

/// The closed set of Siri Remote controls, expressed as SwiftUI move/exit
/// commands rather than raw `GCMicroGamepad` input (see
/// `SemanticSiriRemoteInput`), since the tvOS focus engine already delivers
/// swipe/click/menu as these discrete commands natively.
public enum SiriRemoteControl: Hashable, Sendable, CaseIterable {
    case swipeUp, swipeDown, swipeLeft, swipeRight
    case select, playPause
    /// Reserved: always resolves to ``SemanticDispatchOutcome/reservedBack``.
    case menu
}

/// One physical control across every recognized input family. Deliberately a
/// closed, family-tagged enum (never a raw key code or button index) so
/// ``InputMappingTable`` can only ever be asked about controls this layer
/// actually understands.
public enum PhysicalInput: Hashable, Sendable {
    case keyboard(KeyboardControl)
    case controller(ControllerControl)
    case siriRemote(SiriRemoteControl)

    /// Whether this control is reserved for system back/menu/escape behavior.
    /// Reserved controls are never stored in an ``InputMappingTable`` and
    /// always resolve to ``SemanticDispatchOutcome/reservedBack`` regardless
    /// of any table, so no remap can ever repurpose or swallow them.
    public var isReserved: Bool {
        switch self {
        case .keyboard(.escape), .controller(.buttonMenu), .controller(.buttonHome),
             .siriRemote(.menu):
            true
        default:
            false
        }
    }
}
