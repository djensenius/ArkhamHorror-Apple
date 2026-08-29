@testable import ArkhamHorrorShared
import Testing

/// Coverage for the closed ``SemanticCommand`` vocabulary itself: every case is
/// unique, `isRepeatable` matches the documented continuous/discrete split, and
/// ``PhysicalInput/isReserved`` names exactly the system back/menu/escape controls
/// and nothing else — so reserved behavior can never silently drift to cover (or
/// stop covering) a control.
@Suite("SemanticCommand — closed vocabulary")
struct SemanticCommandTests {
    @Test("allCases contains no duplicate command, including associated-value cases")
    func allCasesHasNoDuplicates() {
        let all = SemanticCommand.allCases
        #expect(Set(all).count == all.count)
    }

    @Test("allCases enumerates every FocusDirection/CycleDirection/RotationDirection payload")
    func allCasesCoversEveryPayload() {
        let all = Set(SemanticCommand.allCases)
        for direction in FocusDirection.allCases {
            #expect(all.contains(.focusMove(direction)))
        }
        for direction in CycleDirection.allCases {
            #expect(all.contains(.cyclePlayer(direction)))
            #expect(all.contains(.cycleZone(direction)))
        }
        for direction in RotationDirection.allCases {
            #expect(all.contains(.rotateCamera(direction)))
        }
    }

    @Test(
        "isRepeatable is true only for continuous/relative commands",
        arguments: SemanticCommand.allCases
    )
    func isRepeatableMatchesContinuousCommands(command: SemanticCommand) {
        // Deliberately an explicit, independently-enumerated literal set —
        // not a copy of `isRepeatable`'s own switch statement — so a future
        // regression in that switch (for example a case moved to the wrong
        // branch) cannot share the same latent bug as this test's own
        // "expected" derivation.
        let repeatableCommands: Set<SemanticCommand> = [
            .focusMove(.up), .focusMove(.down), .focusMove(.left), .focusMove(.right),
            .zoomIn, .zoomOut,
            .rotateCamera(.clockwise), .rotateCamera(.counterclockwise),
            .cyclePlayer(.next), .cyclePlayer(.previous),
            .cycleZone(.next), .cycleZone(.previous),
        ]
        #expect(command.isRepeatable == repeatableCommands.contains(command))
    }

    @Test("isReserved is true for exactly keyboard escape, controller menu/home, and Siri menu")
    func isReservedNamesExactlyTheReservedControls() {
        var reservedCount = 0
        for control in KeyboardControl.allCases {
            let expected = control == .escape
            #expect(PhysicalInput.keyboard(control).isReserved == expected)
            if expected {
                reservedCount += 1
            }
        }
        for control in ControllerControl.allCases {
            let expected = control == .buttonMenu || control == .buttonHome
            #expect(PhysicalInput.controller(control).isReserved == expected)
            if expected {
                reservedCount += 1
            }
        }
        for control in SiriRemoteControl.allCases {
            let expected = control == .menu
            #expect(PhysicalInput.siriRemote(control).isReserved == expected)
            if expected {
                reservedCount += 1
            }
        }
        #expect(reservedCount == 4)
    }
}
