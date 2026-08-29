@testable import ArkhamHorrorShared
import Testing

/// Deterministic coverage of ``SessionUnavailableReason/message``'s exact user-facing
/// semantics for `.probeFailed`. ``CapabilityProbeError`` has cases where the server
/// was never reached (``CapabilityProbeError/transportFailure(_:)``,
/// ``CapabilityProbeError/nonHTTPResponse``) and cases where it *was* reached but
/// returned something unexpected (``CapabilityProbeError/unexpectedStatus(_:)``,
/// ``CapabilityProbeError/malformedPayload(_:)``); the message must not claim
/// unreachability for the latter, and must never surface either case's raw
/// diagnostic string.
@Suite("SessionUnavailableReason message")
struct SessionUnavailableReasonMessageTests {
    private let unreachableCases: [CapabilityProbeError] = [
        .transportFailure("some diagnostic that must never leak"),
        .nonHTTPResponse,
    ]

    private let respondedUnexpectedlyCases: [CapabilityProbeError] = [
        .unexpectedStatus(500),
        .malformedPayload("some decoder diagnostic that must never leak"),
    ]

    @Test("Transport/non-HTTP failures claim the server could not be reached")
    func unreachableCasesClaimUnreachability() {
        for probeError in unreachableCases {
            let message = SessionUnavailableReason.probeFailed(probeError).message
            #expect(message.contains("could not be reached"))
        }
    }

    @Test("Unexpected-status/malformed-payload failures do not falsely claim unreachability")
    func respondedUnexpectedlyCasesDoNotClaimUnreachability() {
        for probeError in respondedUnexpectedlyCases {
            let message = SessionUnavailableReason.probeFailed(probeError).message
            #expect(!message.contains("could not be reached"))
            #expect(!message.lowercased().contains("check your connection"))
        }
    }

    @Test("The message never surfaces a raw probe diagnostic string")
    func messageNeverSurfacesRawDiagnostics() {
        let allCases = unreachableCases + respondedUnexpectedlyCases
        for probeError in allCases {
            let message = SessionUnavailableReason.probeFailed(probeError).message
            #expect(!message.contains("diagnostic that must never leak"))
        }
    }
}
