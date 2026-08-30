@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ServerCapabilities")
struct ServerCapabilitiesTests {
    // MARK: - Canonical fixture

    private func loadFixture() throws -> ServerCapabilities {
        let url = try #require(
            Bundle.module.url(
                forResource: "capabilities",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(ServerCapabilities.self, from: Data(contentsOf: url))
    }

    @Test("Canonical vendored fixture decodes correctly")
    func canonicalFixtureDecodes() throws {
        let caps = try loadFixture()
        #expect(caps.schemaRevision == ContractRevision.literal(major: 0, minor: 1, patch: 21))
        #expect(caps.status == .baselineIncomplete)
        #expect(caps.apiBasePath == "/api/v1")
        let expectedClientMin = ContractRevision.literal(major: 0, minor: 1, patch: 0)
        #expect(caps.nativeClientMinimumRevision == expectedClientMin)
        #expect(caps.capabilities.contains("websockets.authorization-header"))
        #expect(caps.capabilities.contains("events.shared-state-versioning"))
        #expect(caps.capabilities.contains("games.step-probe"))
        #expect(caps.capabilities.contains("websockets.spectator-read-only"))
    }

    @Test("Canonical fixture fields match ContractPin.current source metadata")
    func canonicalFixtureDriftAssertion() throws {
        let caps = try loadFixture()
        let pin = ContractPin.current
        // If any of these fail, the vendored fixture has drifted from the compiled-in pin.
        // Update ContractPin.current or re-vendor the fixture from the correct commit.
        #expect(
            caps.schemaRevision == pin.supportedSchemaRevision,
            "Fixture schemaRevision drifted from pin.supportedSchemaRevision"
        )
        #expect(
            caps.apiBasePath == pin.expectedApiBasePath,
            "Fixture apiBasePath drifted from pin.expectedApiBasePath"
        )
        #expect(
            caps.nativeClientMinimumRevision == pin.sourceNativeClientMinimumRevision,
            "Fixture nativeClientMinimumRevision drifted from pin.sourceNativeClientMinimumRevision"
        )
    }

    // MARK: - Forward compatibility

    @Test("Unknown future capability strings are preserved without error")
    func unknownCapabilitiesPreserved() throws {
        let json = """
        {
            "schemaRevision": "0.1.12",
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": ["known.feature", "unknown.future.capability.xyz"]
        }
        """
        let caps = try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        #expect(caps.capabilities.contains("unknown.future.capability.xyz"))
        #expect(caps.capabilities.contains("known.feature"))
    }

    @Test("Unknown future status string is preserved without failing decoding")
    func unknownStatusPreserved() throws {
        let json = """
        {
            "schemaRevision": "0.1.12",
            "status": "future-status-v3-not-yet-defined",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": []
        }
        """
        let caps = try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        #expect(caps.status.rawValue == "future-status-v3-not-yet-defined")
        #expect(caps.status != .stable)
        #expect(caps.status != .baselineIncomplete)
    }

    @Test("Unknown extra object fields are accepted (additive forward compatibility)")
    func unknownExtraFieldsAccepted() throws {
        let json = """
        {
            "schemaRevision": "0.1.12",
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": [],
            "futureField": "some-value",
            "anotherNewField": 42
        }
        """
        // Decoding must not fail when unknown top-level keys are present.
        let caps = try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        #expect(caps.schemaRevision == ContractRevision.literal(major: 0, minor: 1, patch: 12))
    }

    // MARK: - Known status values

    @Test(
        "Known status strings decode to matching constants",
        arguments: [
            ("baseline-incomplete", ContractStatus.baselineIncomplete),
            ("stable", ContractStatus.stable),
        ]
    )
    func knownStatusDecode(raw: String, expected: ContractStatus) throws {
        let json = """
        {
            "schemaRevision": "0.1.0",
            "status": "\(raw)",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": []
        }
        """
        let caps = try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        #expect(caps.status == expected)
    }

    // MARK: - Decoding edge coverage

    @Test("Empty capabilities array decodes to empty set")
    func emptyCapabilities() throws {
        let json = """
        {
            "schemaRevision": "0.1.12",
            "status": "stable",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": []
        }
        """
        let caps = try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        #expect(caps.capabilities.isEmpty)
    }

    @Test("Missing required field produces a decoding error")
    func missingRequiredField() {
        // schemaRevision is absent
        let json = """
        {
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": []
        }
        """
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        }
    }

    @Test("Wrong JSON type for schemaRevision produces a decoding error")
    func wrongTypeForSchemaRevision() {
        // schemaRevision must be a string, not a number
        let json = """
        {
            "schemaRevision": 11,
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": []
        }
        """
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        }
    }

    @Test("Non-string capability member produces a decoding error")
    func nonStringCapabilityMember() {
        // capabilities must be [String]; an integer element must fail
        let json = """
        {
            "schemaRevision": "0.1.12",
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": ["valid.cap", 42]
        }
        """
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(ServerCapabilities.self, from: Data(json.utf8))
        }
    }
}
