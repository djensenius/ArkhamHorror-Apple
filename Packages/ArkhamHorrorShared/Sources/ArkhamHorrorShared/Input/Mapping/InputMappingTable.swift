import Foundation

/// A pure, remappable table from non-reserved physical controls to
/// ``SemanticCommand``s.
///
/// Reserved controls (``PhysicalInput/isReserved``) are never stored here —
/// they are handled directly as system back/menu/escape by
/// ``SemanticInputRouter`` — so both a lookup and a rebind attempt against one
/// are always rejected rather than silently accepted. Because storage is a
/// dictionary keyed by the physical control, one physical input can be bound
/// to at most one command at a time by construction; several different
/// physical inputs may still be bound to the same command (for example both
/// a keyboard key and a controller button bound to `.inspect`).
struct InputMappingTable: Sendable, Equatable {
    private(set) var bindings: [PhysicalInput: SemanticCommand]

    init(bindings: [PhysicalInput: SemanticCommand] = [:]) {
        self.bindings = bindings.filter { !$0.key.isReserved }
    }

    /// The command bound to `input`, or `nil` if `input` is reserved or
    /// unbound. Unbound (unknown-to-this-table) input is always safe: it
    /// simply produces no command, never a fallback guess.
    func command(for input: PhysicalInput) -> SemanticCommand? {
        guard !input.isReserved else { return nil }
        return bindings[input]
    }

    /// The outcome of a ``rebind(_:to:)`` attempt.
    enum RebindResult: Equatable {
        /// The binding was applied. `previousCommand` is whatever `input` was
        /// previously bound to, if anything, so a settings UI can surface
        /// what was displaced.
        case applied(previousCommand: SemanticCommand?)
        /// `input` is reserved and can never be rebound.
        case rejectedReserved
    }

    /// Binds `input` to `command`, replacing any prior binding for that exact
    /// physical input. Rejected outright for a reserved input.
    @discardableResult
    mutating func rebind(_ input: PhysicalInput, to command: SemanticCommand) -> RebindResult {
        guard !input.isReserved else { return .rejectedReserved }
        let previous = bindings[input]
        bindings[input] = command
        return .applied(previousCommand: previous)
    }

    /// Removes any binding for `input`. A no-op for a reserved or already
    /// unbound input.
    mutating func unbind(_ input: PhysicalInput) {
        bindings[input] = nil
    }
}

extension InputMappingTable {
    /// The default keyboard bindings. Arrow keys move focus; Return/Space are
    /// primary/secondary action; Escape is reserved (see
    /// ``PhysicalInput/isReserved``) and is not listed here.
    static let defaultKeyboard = InputMappingTable(bindings: [
        .keyboard(.arrowUp): .focusMove(.up),
        .keyboard(.arrowDown): .focusMove(.down),
        .keyboard(.arrowLeft): .focusMove(.left),
        .keyboard(.arrowRight): .focusMove(.right),
        .keyboard(.enter): .primaryAction,
        .keyboard(.space): .secondaryAction,
        .keyboard(.letterI): .inspect,
        .keyboard(.letterH): .toggleHandSurface,
        .keyboard(.letterP): .togglePromptSurface,
        .keyboard(.letterV): .toggleInvestigatorSurface,
        .keyboard(.letterL): .toggleLogSurface,
        .keyboard(.letterM): .toggleMenuSurface,
        .keyboard(.tab): .cyclePlayer(.next),
        .keyboard(.letterN): .cycleZone(.next),
        .keyboard(.letterB): .jumpToActivePrompt,
        .keyboard(.equals): .zoomIn,
        .keyboard(.minus): .zoomOut,
        .keyboard(.leftBracket): .rotateCamera(.counterclockwise),
        .keyboard(.rightBracket): .rotateCamera(.clockwise),
        .keyboard(.letterZ): .undo,
        .keyboard(.letterA): .toggleArrangeMode,
    ])

    /// The default extended-gamepad bindings shared by every generic
    /// controller family. `GCExtendedGamepad` already normalizes button
    /// *position* (buttonA is always the bottom face button) independently of
    /// brand glyph, so Xbox/PlayStation/MFi controllers share one binding set
    /// today; ``defaultXbox``, ``defaultPlayStation``, and ``defaultMFi`` are
    /// declared as distinct named values so a future per-brand override never
    /// has to change call sites. buttonMenu/buttonHome are reserved and are
    /// not listed here.
    static let defaultGamepad = InputMappingTable(bindings: [
        .controller(.dpadUp): .focusMove(.up),
        .controller(.dpadDown): .focusMove(.down),
        .controller(.dpadLeft): .focusMove(.left),
        .controller(.dpadRight): .focusMove(.right),
        .controller(.buttonA): .primaryAction,
        .controller(.buttonB): .secondaryAction,
        .controller(.buttonY): .inspect,
        .controller(.buttonX): .jumpToActivePrompt,
        .controller(.leftShoulder): .cyclePlayer(.previous),
        .controller(.rightShoulder): .cyclePlayer(.next),
        .controller(.leftTrigger): .cycleZone(.previous),
        .controller(.rightTrigger): .cycleZone(.next),
        .controller(.buttonOptions): .toggleMenuSurface,
        .controller(.leftThumbstickButton): .resetCamera,
        .controller(.rightThumbstickButton): .toggleArrangeMode,
    ])

    static let defaultXbox = defaultGamepad
    static let defaultPlayStation = defaultGamepad
    static let defaultMFi = defaultGamepad

    /// The default table for a given controller glyph family. `.unknown`
    /// still uses ``defaultGamepad`` since an unrecognized brand's extended
    /// gamepad profile is structurally identical; only glyph rendering (not
    /// binding) would differ for a genuinely unsupported profile.
    static func defaultTable(for glyphFamily: ControllerGlyphFamily) -> InputMappingTable {
        switch glyphFamily {
        case .xbox: .defaultXbox
        case .playStation: .defaultPlayStation
        case .mfi: .defaultMFi
        case .unknown: .defaultGamepad
        }
    }

    /// The default Siri Remote bindings. Menu is reserved and is not listed
    /// here.
    static let defaultSiriRemote = InputMappingTable(bindings: [
        .siriRemote(.swipeUp): .focusMove(.up),
        .siriRemote(.swipeDown): .focusMove(.down),
        .siriRemote(.swipeLeft): .focusMove(.left),
        .siriRemote(.swipeRight): .focusMove(.right),
        .siriRemote(.select): .primaryAction,
        .siriRemote(.playPause): .toggleMenuSurface,
    ])
}
