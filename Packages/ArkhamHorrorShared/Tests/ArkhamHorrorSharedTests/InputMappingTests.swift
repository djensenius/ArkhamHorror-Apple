@testable import ArkhamHorrorShared
import SwiftUI
import Testing

/// Coverage for the pure input-mapping/remapping model: every default table's exact
/// bindings, reserved-input rejection on both lookup and rebind, the one-physical-
/// input-to-at-most-one-command invariant, unknown-input safety, and
/// ``SemanticInputRouter``'s press/repeat/release policy.
@Suite("InputMappingTable and SemanticInputRouter — pure mapping")
struct InputMappingTests {
    // MARK: - Default keyboard bindings

    @Test("defaultKeyboard binds exactly the documented keys to the documented commands")
    func defaultKeyboardBindsExactly() {
        let table = InputMappingTable.defaultKeyboard
        let expected: [KeyboardControl: SemanticCommand] = [
            .arrowUp: .focusMove(.up),
            .arrowDown: .focusMove(.down),
            .arrowLeft: .focusMove(.left),
            .arrowRight: .focusMove(.right),
            .enter: .primaryAction,
            .space: .secondaryAction,
            .letterI: .inspect,
            .letterH: .toggleHandSurface,
            .letterP: .togglePromptSurface,
            .letterV: .toggleInvestigatorSurface,
            .letterL: .toggleLogSurface,
            .letterM: .toggleMenuSurface,
            .tab: .cyclePlayer(.next),
            .letterN: .cycleZone(.next),
            .letterB: .jumpToActivePrompt,
            .equals: .zoomIn,
            .minus: .zoomOut,
            .leftBracket: .rotateCamera(.counterclockwise),
            .rightBracket: .rotateCamera(.clockwise),
            .letterZ: .undo,
            .letterA: .toggleArrangeMode,
        ]
        for control in KeyboardControl.allCases where control != .escape {
            #expect(table.command(for: .keyboard(control)) == expected[control])
        }
        // Escape is reserved and must never appear as a lookup-able binding.
        #expect(table.command(for: .keyboard(.escape)) == nil)
    }

    // MARK: - Default gamepad bindings (shared across brands)

    @Test("defaultGamepad binds exactly the documented buttons to the documented commands")
    func defaultGamepadBindsExactly() {
        let table = InputMappingTable.defaultGamepad
        let expected: [ControllerControl: SemanticCommand] = [
            .dpadUp: .focusMove(.up),
            .dpadDown: .focusMove(.down),
            .dpadLeft: .focusMove(.left),
            .dpadRight: .focusMove(.right),
            .buttonA: .primaryAction,
            .buttonB: .secondaryAction,
            .buttonY: .inspect,
            .buttonX: .jumpToActivePrompt,
            .leftShoulder: .cyclePlayer(.previous),
            .rightShoulder: .cyclePlayer(.next),
            .leftTrigger: .cycleZone(.previous),
            .rightTrigger: .cycleZone(.next),
            .buttonOptions: .toggleMenuSurface,
            .leftThumbstickButton: .resetCamera,
            .rightThumbstickButton: .toggleArrangeMode,
        ]
        let reserved: Set<ControllerControl> = [.buttonMenu, .buttonHome]
        for control in ControllerControl.allCases where !reserved.contains(control) {
            #expect(table.command(for: .controller(control)) == expected[control])
        }
        #expect(table.command(for: .controller(.buttonMenu)) == nil)
        #expect(table.command(for: .controller(.buttonHome)) == nil)
    }

    @Test(
        "Every brand-specific default gamepad table is identical to defaultGamepad",
        arguments: [
            ControllerGlyphFamily.xbox, .playStation, .mfi, .unknown,
        ]
    )
    func brandSpecificDefaultsMatchSharedGamepadTable(glyphFamily: ControllerGlyphFamily) {
        #expect(InputMappingTable.defaultTable(for: glyphFamily) == .defaultGamepad)
    }

    // MARK: - Default Siri Remote bindings

    @Test("defaultSiriRemote binds exactly the documented controls to the documented commands")
    func defaultSiriRemoteBindsExactly() {
        let table = InputMappingTable.defaultSiriRemote
        let expected: [SiriRemoteControl: SemanticCommand] = [
            .swipeUp: .focusMove(.up),
            .swipeDown: .focusMove(.down),
            .swipeLeft: .focusMove(.left),
            .swipeRight: .focusMove(.right),
            .select: .primaryAction,
            .playPause: .toggleMenuSurface,
        ]
        for control in SiriRemoteControl.allCases where control != .menu {
            #expect(table.command(for: .siriRemote(control)) == expected[control])
        }
        #expect(table.command(for: .siriRemote(.menu)) == nil)
    }

    // MARK: - Reserved-input conflict handling

    @Test(
        "Constructing a table with a reserved input in its initial bindings silently drops it",
        arguments: [
            PhysicalInput.keyboard(.escape), .controller(.buttonMenu), .controller(.buttonHome),
            .siriRemote(.menu),
        ]
    )
    func constructingWithReservedBindingDropsIt(input: PhysicalInput) {
        let table = InputMappingTable(bindings: [input: .undo])
        #expect(table.command(for: input) == nil)
        #expect(table.bindings[input] == nil)
    }

    @Test(
        "rebind rejects every reserved input and leaves the table unchanged",
        arguments: [
            PhysicalInput.keyboard(.escape), .controller(.buttonMenu), .controller(.buttonHome),
            .siriRemote(.menu),
        ]
    )
    func rebindRejectsReservedInput(input: PhysicalInput) {
        var table = InputMappingTable()
        let result = table.rebind(input, to: .undo)
        #expect(result == .rejectedReserved)
        #expect(table.command(for: input) == nil)
    }

    // MARK: - Rebind / unbind / one-input-to-at-most-one-command

    @Test("rebind reports the previously bound command and replaces it")
    func rebindReportsAndReplacesPreviousBinding() {
        var table = InputMappingTable.defaultKeyboard
        let result = table.rebind(.keyboard(.enter), to: .inspect)
        #expect(result == .applied(previousCommand: .primaryAction))
        #expect(table.command(for: .keyboard(.enter)) == .inspect)
    }

    @Test("rebind on a previously unbound input reports a nil previous command")
    func rebindOnUnboundInputReportsNilPrevious() {
        var table = InputMappingTable()
        let result = table.rebind(.keyboard(.letterI), to: .inspect)
        #expect(result == .applied(previousCommand: nil))
    }

    @Test("One physical input is bound to at most one command, even after repeated rebinds")
    func onePhysicalInputBindsToAtMostOneCommand() {
        var table = InputMappingTable()
        table.rebind(.keyboard(.letterI), to: .inspect)
        table.rebind(.keyboard(.letterI), to: .undo)
        table.rebind(.keyboard(.letterI), to: .toggleArrangeMode)
        #expect(table.bindings.count == 1)
        #expect(table.command(for: .keyboard(.letterI)) == .toggleArrangeMode)
    }

    @Test("unbind removes a binding, and is a safe no-op for an already-unbound input")
    func unbindRemovesBindingAndIsSafeForUnboundInput() {
        var table = InputMappingTable.defaultKeyboard
        table.unbind(.keyboard(.arrowUp))
        #expect(table.command(for: .keyboard(.arrowUp)) == nil)
        // Repeating unbind on the same (now-unbound) input must not crash or throw.
        table.unbind(.keyboard(.arrowUp))
        #expect(table.command(for: .keyboard(.arrowUp)) == nil)
    }

    @Test("An input this layer has never bound safely produces no command")
    func unknownInputIsSafe() {
        let table = InputMappingTable()
        #expect(table.command(for: .keyboard(.letterI)) == nil)
        #expect(table.command(for: .controller(.buttonY)) == nil)
        #expect(table.command(for: .siriRemote(.select)) == nil)
    }

    // MARK: - SemanticInputRouter phase policy

    @Test("A press on a bound, non-reserved input dispatches its command")
    func pressDispatchesCommand() {
        let outcome = SemanticInputRouter.route(
            PhysicalInputEvent(input: .keyboard(.enter), phase: .press), using: .defaultKeyboard
        )
        #expect(outcome == .command(.primaryAction))
    }

    @Test("Release never dispatches anything, bound or not, reserved or not")
    func releaseNeverDispatches() {
        #expect(
            SemanticInputRouter.route(
                PhysicalInputEvent(input: .keyboard(.enter), phase: .release),
                using: .defaultKeyboard
            ) == nil
        )
        #expect(
            SemanticInputRouter.route(
                PhysicalInputEvent(input: .keyboard(.escape), phase: .release),
                using: .defaultKeyboard
            ) == nil
        )
    }

    @Test("Repeat only dispatches when the bound command is repeatable")
    func repeatOnlyDispatchesForRepeatableCommands() {
        // .arrowUp -> .focusMove(.up) is repeatable.
        #expect(
            SemanticInputRouter.route(
                PhysicalInputEvent(input: .keyboard(.arrowUp), phase: .repeatPress),
                using: .defaultKeyboard
            ) == .command(.focusMove(.up))
        )
        // .enter -> .primaryAction is not repeatable.
        #expect(
            SemanticInputRouter.route(
                PhysicalInputEvent(input: .keyboard(.enter), phase: .repeatPress),
                using: .defaultKeyboard
            ) == nil
        )
    }

    @Test("A reserved input yields reservedBack on press, but never on repeat (a held key)")
    func reservedInputYieldsReservedBackOnlyOnPress() {
        #expect(
            SemanticInputRouter.route(
                PhysicalInputEvent(input: .keyboard(.escape), phase: .press),
                using: .defaultKeyboard
            ) == .reservedBack
        )
        // A held reserved key repeats like any other input, but must never
        // repeatedly dismiss/pop more than the single modal a single press
        // should — unlike a repeatable bound command, there is no notion of
        // "reservedBack is repeatable" at all.
        #expect(
            SemanticInputRouter.route(
                PhysicalInputEvent(input: .keyboard(.escape), phase: .repeatPress),
                using: .defaultKeyboard
            ) == nil
        )
    }

    @Test("An unmapped input safely yields no outcome")
    func unmappedInputYieldsNoOutcome() {
        let outcome = SemanticInputRouter.route(
            PhysicalInputEvent(input: .keyboard(.letterI), phase: .press),
            using: InputMappingTable()
        )
        #expect(outcome == nil)
    }

    // MARK: - Keyboard adapter's pure key/phase mapping

    @Test("KeyboardControl recognizes every documented KeyEquivalent and rejects unrecognized keys")
    func keyboardControlMapsDocumentedKeys() {
        #expect(KeyboardControl(.upArrow) == .arrowUp)
        #expect(KeyboardControl(.downArrow) == .arrowDown)
        #expect(KeyboardControl(.leftArrow) == .arrowLeft)
        #expect(KeyboardControl(.rightArrow) == .arrowRight)
        #expect(KeyboardControl(.space) == .space)
        #expect(KeyboardControl(.return) == .enter)
        #expect(KeyboardControl(.tab) == .tab)
        #expect(KeyboardControl(.escape) == .escape)
        #expect(KeyboardControl("i") == .letterI)
        #expect(KeyboardControl("z") == .letterZ)
        #expect(KeyboardControl("q") == nil)
        #expect(KeyboardControl("9") == nil)
    }

    @Test("InputPhase maps KeyPress.Phases with down taking priority, then repeat, then up")
    func inputPhaseMapsKeyPressPhases() {
        #expect(InputPhase(.down) == .press)
        #expect(InputPhase(.repeat) == .repeatPress)
        #expect(InputPhase(.up) == .release)
        #expect(InputPhase([.down, .repeat]) == .press)
    }
}
