@testable import ArkhamHorrorShared
import Testing

/// Deterministic coverage of ``SessionStorageFailure/message``'s exact user-facing
/// semantics: it must never promise a non-destructive retry (`AppModel.retry()` is a
/// no-op for `.storageCorrupted`, and `ServerIssueView` offers only a destructive
/// reset for this state), and it must truthfully describe what resetting does and
/// does not remove. Deliberately avoids a brittle full-string equality check so the
/// exact copy can still be refined without breaking this test over unrelated wording.
@Suite("SessionStorageFailure message")
struct SessionStorageFailureMessageTests {
    private let failures: [SessionStorageFailure] = [
        .profileStore(.corruptData(key: "ArkhamHorror.serverProfiles")),
        .profileStore(.corruptData(key: "ArkhamHorror.selectedServerProfileID")),
        .unexpected,
    ]

    @Test("The message never implies a non-destructive retry path")
    func messageNeverImpliesRetryWithoutLoss() {
        for failure in failures {
            let message = failure.message.lowercased()
            #expect(!message.contains("try again"))
            #expect(!message.contains("without losing"))
            #expect(!message.contains("later"))
        }
    }

    @Test("The message truthfully names what resetting removes and preserves")
    func messageDescribesResetTruthfully() {
        for failure in failures {
            let message = failure.message
            #expect(message.contains("custom servers"))
            #expect(message.contains("sign-in"))
            #expect(message.contains("hosted"))
        }
    }

    @Test("The message never surfaces a raw storage key or decoder diagnostic")
    func messageNeverSurfacesRawDiagnostics() {
        for failure in failures {
            #expect(!failure.message.contains("ArkhamHorror."))
        }
    }
}
