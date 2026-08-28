@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Test doubles

private struct StubTransport: CapabilityProbeTransport {
    let stubData: Data
    let stubResponse: URLResponse

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        (stubData, stubResponse)
    }
}

// MARK: - Tests

@Suite("CapabilityProbe")
struct CapabilityProbeTests {
    private let defaultProfile = ServerProfile.hosted

    // MARK: - Helpers

    private func makeHTTPResponse(status: Int, url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? defaultProfile.capabilitiesURL(),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func canonicalCapabilitiesData() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "capabilities",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func stub(data: Data, status: Int) -> StubTransport {
        StubTransport(stubData: data, stubResponse: makeHTTPResponse(status: status))
    }

    // MARK: - Compatible fixture

    @Test("Canonical capabilities fixture through the probe produces .compatible")
    func canonicalFixtureCompatible() async throws {
        let fixtureData = try canonicalCapabilitiesData()
        let transport = stub(data: fixtureData, status: 200)
        let probe = CapabilityProbe(transport: transport)
        let outcome = try await probe.probe(defaultProfile)
        if case .compatible = outcome {} else {
            Issue.record("Expected .compatible, got \(outcome)")
        }
    }

    @Test("Compatible server's capability set is forwarded in the .compatible outcome")
    func compatibleCapabilitiesForwarded() async throws {
        let json = """
        {
            "schemaRevision": "0.1.11",
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": ["websockets.authorization-header"]
        }
        """
        let transport = stub(data: Data(json.utf8), status: 200)
        let probe = CapabilityProbe(transport: transport)
        let outcome = try await probe.probe(defaultProfile)
        #expect(outcome == .compatible(capabilities: ["websockets.authorization-header"]))
    }

    // MARK: - Legacy fallback (HTTP 404)

    @Test("HTTP 404 returns .legacyFallback with no assumed capabilities")
    func http404LegacyFallback() async throws {
        let transport = stub(data: Data(), status: 404)
        let probe = CapabilityProbe(transport: transport)
        let outcome = try await probe.probe(defaultProfile)
        #expect(outcome == .legacyFallback)
    }

    @Test("404 response body is ignored when returning .legacyFallback")
    func http404BodyIgnored() async throws {
        let transport = stub(data: Data("irrelevant body".utf8), status: 404)
        let probe = CapabilityProbe(transport: transport)
        let outcome = try await probe.probe(defaultProfile)
        #expect(outcome == .legacyFallback)
    }

    // MARK: - Incompatible server

    @Test("A schema revision older than the minimum returns .incompatible(.serverTooOld)")
    func serverTooOldReturnsIncompatible() async throws {
        let json = """
        {
            "schemaRevision": "0.1.0",
            "status": "baseline-incomplete",
            "apiBasePath": "/api/v1",
            "nativeClientMinimumRevision": "0.1.0",
            "capabilities": []
        }
        """
        let transport = stub(data: Data(json.utf8), status: 200)
        let probe = CapabilityProbe(transport: transport)
        let outcome = try await probe.probe(defaultProfile)
        if case .incompatible(.serverTooOld) = outcome {} else {
            Issue.record("Expected .incompatible(.serverTooOld), got \(outcome)")
        }
    }

    // MARK: - Malformed JSON payload

    @Test("Non-JSON 2xx body throws malformedPayload")
    func nonJSONBodyThrows() async {
        let transport = stub(data: Data("not json".utf8), status: 200)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.malformedPayload("")) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("Valid JSON with wrong shape throws malformedPayload")
    func wrongShapeJSONThrows() async {
        let transport = stub(data: Data(#"{"foo":"bar"}"#.utf8), status: 200)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.malformedPayload("")) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("Empty body on a 2xx response throws malformedPayload")
    func emptyBodyOnSuccessThrows() async {
        let transport = stub(data: Data(), status: 200)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.malformedPayload("")) {
            try await probe.probe(defaultProfile)
        }
    }

    // MARK: - Non-2xx status codes

    @Test("HTTP 500 throws unexpectedStatus(500)")
    func http500Throws() async {
        let transport = stub(data: Data(), status: 500)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.unexpectedStatus(500)) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("HTTP 401 throws unexpectedStatus(401)")
    func http401Throws() async {
        let transport = stub(data: Data(), status: 401)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.unexpectedStatus(401)) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("HTTP 301 throws unexpectedStatus(301)")
    func http301Throws() async {
        let transport = stub(data: Data(), status: 301)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.unexpectedStatus(301)) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("HTTP 503 throws unexpectedStatus(503)")
    func http503Throws() async {
        let transport = stub(data: Data(), status: 503)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.unexpectedStatus(503)) {
            try await probe.probe(defaultProfile)
        }
    }

    // MARK: - Non-HTTP response

    @Test("A non-HTTP URLResponse throws nonHTTPResponse")
    func nonHTTPResponseThrows() async {
        let nonHTTP = URLResponse(
            url: defaultProfile.capabilitiesURL(),
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        let transport = StubTransport(stubData: Data(), stubResponse: nonHTTP)
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.nonHTTPResponse) {
            try await probe.probe(defaultProfile)
        }
    }
}
