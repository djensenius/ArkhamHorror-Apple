@testable import ArkhamHorrorShared
import Testing

@Suite("CompatibilityEvaluator")
struct CompatibilityEvaluatorTests {
    /// Evaluator using the compiled-in pin (supportedSchemaRevision 0.1.21, min server 0.1.21,
    /// path /api/v1)
    private let evaluator = CompatibilityEvaluator(pin: .current)

    /// A baseline-compatible server response for tests that vary individual fields.
    private func compatibleServer(
        schemaRevision: ContractRevision = .literal(major: 0, minor: 1, patch: 21),
        nativeClientMinimumRevision: ContractRevision = .literal(major: 0, minor: 1, patch: 0),
        apiBasePath: String = "/api/v1",
        capabilities: Set<String> = []
    ) -> ServerCapabilities {
        ServerCapabilities(
            schemaRevision: schemaRevision,
            status: .baselineIncomplete,
            apiBasePath: apiBasePath,
            nativeClientMinimumRevision: nativeClientMinimumRevision,
            capabilities: capabilities
        )
    }

    // MARK: - Compatible outcomes

    @Test("Compatible server produces .compatible with the server's capabilities")
    func compatibleOutcome() {
        let caps = compatibleServer(capabilities: ["websockets.authorization-header"])
        let outcome = evaluator.evaluate(caps)
        #expect(outcome == .compatible(capabilities: ["websockets.authorization-header"]))
    }

    @Test("Unknown additive capabilities are forwarded in .compatible")
    func unknownCapabilitiesForwarded() {
        let caps = compatibleServer(capabilities: ["known.cap", "future.unknown.cap"])
        let outcome = evaluator.evaluate(caps)
        #expect(
            outcome == .compatible(capabilities: ["known.cap", "future.unknown.cap"])
        )
    }

    @Test("Server at exactly the minimum schema revision is compatible")
    func exactMinimumSchemaRevision() {
        let caps = compatibleServer(
            schemaRevision: .literal(major: 0, minor: 1, patch: 21)
        )
        let outcome = evaluator.evaluate(caps)
        if case .compatible = outcome {} else {
            Issue.record("Expected .compatible, got \(outcome)")
        }
    }

    @Test("Server minimum 0.1.0 accepts a client that supports 0.1.21")
    func serverMinimumAcceptsClient() {
        // pin.supportedSchemaRevision 0.1.21 >= server floor 0.1.0: compatible
        let caps = compatibleServer(
            nativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
        )
        let outcome = evaluator.evaluate(caps)
        if case .compatible = outcome {} else {
            Issue.record("Expected .compatible, got \(outcome)")
        }
    }

    @Test("Server schema 0.1.22 is accepted when its client floor remains <=0.1.21")
    func higherServerSchemaAccepted() {
        // server 0.1.22 > client minimum 0.1.21: passes serverTooOld check
        // server floor 0.1.21 <= client supports 0.1.21: passes clientTooOld check
        let caps = compatibleServer(
            schemaRevision: .literal(major: 0, minor: 1, patch: 22),
            nativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 21)
        )
        let outcome = evaluator.evaluate(caps)
        if case .compatible = outcome {} else {
            Issue.record("Expected .compatible for server 0.1.22 with floor 0.1.21, got \(outcome)")
        }
    }

    // MARK: - Client too old

    @Test("Server minimum 0.1.22 rejects a client that only supports 0.1.21")
    func serverMinimumRejectsClient() {
        let serverMinimum = ContractRevision.literal(major: 0, minor: 1, patch: 22)
        let caps = compatibleServer(nativeClientMinimumRevision: serverMinimum)
        let outcome = evaluator.evaluate(caps)
        #expect(
            outcome == .incompatible(reason: .clientTooOld(
                clientSupports: .literal(major: 0, minor: 1, patch: 21),
                serverRequires: serverMinimum
            ))
        )
    }

    @Test("Numeric ordering prevents false clientTooOld: 0.1.9 vs 0.1.11")
    func numericClientVersionOrdering() {
        let oldPin = ContractPin(
            backendCommit: "abc",
            supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 9),
            minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 0),
            expectedApiBasePath: "/api/v1",
            sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
        )
        let altEvaluator = CompatibilityEvaluator(pin: oldPin)
        let caps = compatibleServer(
            nativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 11)
        )
        let outcome = altEvaluator.evaluate(caps)
        #expect(
            outcome == .incompatible(reason: .clientTooOld(
                clientSupports: .literal(major: 0, minor: 1, patch: 9),
                serverRequires: .literal(major: 0, minor: 1, patch: 11)
            ))
        )
    }

    // MARK: - Server too old

    @Test("Server schema revision below client minimum produces .serverTooOld")
    func serverTooOld() {
        let caps = compatibleServer(
            schemaRevision: .literal(major: 0, minor: 1, patch: 5)
        )
        let outcome = evaluator.evaluate(caps)
        #expect(
            outcome == .incompatible(reason: .serverTooOld(
                serverRevision: .literal(major: 0, minor: 1, patch: 5),
                clientRequires: .literal(major: 0, minor: 1, patch: 21)
            ))
        )
    }

    @Test("Numeric ordering prevents false serverTooOld: 0.1.9 vs 0.1.20")
    func numericServerVersionOrdering() {
        let caps = compatibleServer(
            schemaRevision: .literal(major: 0, minor: 1, patch: 9)
        )
        let outcome = evaluator.evaluate(caps)
        #expect(
            outcome == .incompatible(reason: .serverTooOld(
                serverRevision: .literal(major: 0, minor: 1, patch: 9),
                clientRequires: .literal(major: 0, minor: 1, patch: 21)
            ))
        )
    }

    // MARK: - API base path mismatch

    @Test("API base path mismatch produces .apiBasePathMismatch")
    func apiBasePathMismatch() {
        let caps = compatibleServer(apiBasePath: "/api/v2")
        let outcome = evaluator.evaluate(caps)
        #expect(
            outcome == .incompatible(reason: .apiBasePathMismatch(
                server: "/api/v2",
                expected: "/api/v1"
            ))
        )
    }

    @Test("API base path /api/v1 is validated exactly")
    func apiBasePathV1Validated() {
        for mismatch in ["/api/v1/", "/API/v1", "/api/V1", "/api/v10", "/api"] {
            let caps = compatibleServer(apiBasePath: mismatch)
            let outcome = evaluator.evaluate(caps)
            if case .incompatible(.apiBasePathMismatch) = outcome {} else {
                Issue.record("Expected apiBasePathMismatch for '\(mismatch)', got \(outcome)")
            }
        }
    }

    // MARK: - Check ordering

    @Test("clientTooOld is reported before serverTooOld when both conditions fail")
    func clientTooOldTakesPrecedence() {
        // client supports 0.1.21 < server floor 0.2.0 → clientTooOld
        // server schema 0.1.0 < client minimum 0.1.21 → serverTooOld (not reached)
        let caps = compatibleServer(
            schemaRevision: .literal(major: 0, minor: 1, patch: 0),
            nativeClientMinimumRevision: .literal(major: 0, minor: 2, patch: 0)
        )
        let outcome = evaluator.evaluate(caps)
        if case .incompatible(.clientTooOld) = outcome {} else {
            Issue.record("Expected .clientTooOld to take precedence, got \(outcome)")
        }
    }

    // MARK: - Legacy fallback

    @Test("Legacy fallback is distinct from incompatible and from compatible with no capabilities")
    func legacyFallbackDistinct() {
        let outcome = evaluator.legacyFallback()
        #expect(outcome == .legacyFallback)
        #expect(outcome != .compatible(capabilities: []))
        #expect(outcome != .incompatible(reason: .apiBasePathMismatch(server: "", expected: "")))
    }
}
