@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Type alias so `GatedTransport`'s generic signatures stay within the line-length limit.
private typealias GateContinuation = CheckedContinuation<(Data, URLResponse), any Error>

/// A transport that blocks `data(for:)` until the caller explicitly releases it.
///
/// Guarantees that the task is already mid-flight before cancellation is injected,
/// making cancellation-propagation tests deterministic across all schedulers.
private actor GatedTransport: CapabilityProbeTransport {
    /// Stored when `data(for:)` delivers its gate before `awaitGate()` is called.
    private var pendingGate: GateContinuation?
    /// Stored when `awaitGate()` is called before `data(for:)` delivers its gate.
    private var gateWaiter: CheckedContinuation<GateContinuation, Never>?

    /// Suspends until `data(for:)` has started, then returns the gate continuation.
    ///
    /// Resume or throw on the returned continuation to unblock the transport call.
    func awaitGate() async -> GateContinuation {
        if let gate = pendingGate {
            pendingGate = nil
            return gate
        }
        return await withCheckedContinuation { gateWaiter = $0 }
    }

    private func deliverGate(_ gate: GateContinuation) {
        if let waiter = gateWaiter {
            waiter.resume(returning: gate)
            gateWaiter = nil
        } else {
            pendingGate = gate
        }
    }

    nonisolated func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { gate in
            Task { await self.deliverGate(gate) }
        }
    }
}

// MARK: - Test doubles (local to this file)

private struct FailingTransport: CapabilityProbeTransport {
    let error: any Error & Sendable

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

private struct TransportFailure: Error, Sendable {}

/// A Sendable recording transport that captures the last URLRequest it received.
private actor RecordingTransport: CapabilityProbeTransport {
    private(set) var capturedRequest: URLRequest?
    private let stubData: Data
    private let stubResponse: URLResponse

    init(data: Data, response: URLResponse) {
        stubData = data
        stubResponse = response
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await record(request)
        return (stubData, stubResponse)
    }

    private func record(_ request: URLRequest) {
        capturedRequest = request
    }
}

@Suite("CapabilityProbe — Transport failures and cancellation")
struct CapabilityProbeTransportTests {
    private let defaultProfile = ServerProfile.hosted

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

    // MARK: - Transport failures

    @Test("A transport-level failure is wrapped in transportFailure")
    func transportFailurePropagates() async {
        let transport = FailingTransport(error: TransportFailure())
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.transportFailure("")) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("A transport-thrown CancellationError is not wrapped in transportFailure")
    func cancellationErrorNotWrapped() async {
        let transport = FailingTransport(error: CancellationError())
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CancellationError.self) {
            try await probe.probe(defaultProfile)
        }
    }

    @Test("URLError.cancelled from a cancelled task surfaces as CancellationError")
    func urlErrorCancelledInCancelledTask() async {
        let transport = GatedTransport()
        let probe = CapabilityProbe(transport: transport)

        let task = Task<CompatibilityOutcome, any Error> {
            try await probe.probe(defaultProfile)
        }

        // Wait until data(for:) is executing and suspended, guaranteeing the task
        // is mid-flight before we cancel it and inject URLError.cancelled.
        let gate = await transport.awaitGate()
        task.cancel()
        gate.resume(throwing: URLError(.cancelled))

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError to be thrown")
        } catch is CancellationError {
            // URLError.cancelled with a cancelled enclosing task → CancellationError
        } catch {
            Issue.record("Expected CancellationError but got: \(error)")
        }
    }

    @Test("A cancelled task cannot return a successful probe result")
    func successfulTransportResultStillChecksCancellation() async throws {
        let capabilitiesData = try canonicalCapabilitiesData()
        let transport = GatedTransport()
        let probe = CapabilityProbe(transport: transport)
        let task = Task<CompatibilityOutcome, any Error> {
            try await probe.probe(defaultProfile)
        }

        let gate = await transport.awaitGate()
        task.cancel()
        gate.resume(returning: (
            capabilitiesData,
            makeHTTPResponse(status: 200)
        ))

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    // MARK: - Request verification

    @Test("Probe issues a GET request")
    func requestMethodIsGET() async throws {
        let fixtureData = try canonicalCapabilitiesData()
        let transport = RecordingTransport(
            data: fixtureData,
            response: makeHTTPResponse(status: 200)
        )
        let probe = CapabilityProbe(transport: transport)
        _ = try await probe.probe(defaultProfile)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
    }

    @Test("Probe sends Accept: application/json")
    func requestAcceptHeader() async throws {
        let fixtureData = try canonicalCapabilitiesData()
        let transport = RecordingTransport(
            data: fixtureData,
            response: makeHTTPResponse(status: 200)
        )
        let probe = CapabilityProbe(transport: transport)
        _ = try await probe.probe(defaultProfile)
        let request = await transport.capturedRequest
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Probe does not send an Authorization header")
    func requestNoAuthorizationHeader() async throws {
        let fixtureData = try canonicalCapabilitiesData()
        let transport = RecordingTransport(
            data: fixtureData,
            response: makeHTTPResponse(status: 200)
        )
        let probe = CapabilityProbe(transport: transport)
        _ = try await probe.probe(defaultProfile)
        let request = await transport.capturedRequest
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Probe sets httpShouldHandleCookies to false on the request")
    func requestCookieHandlingDisabled() async throws {
        let fixtureData = try canonicalCapabilitiesData()
        let transport = RecordingTransport(
            data: fixtureData,
            response: makeHTTPResponse(status: 200)
        )
        let probe = CapabilityProbe(transport: transport)
        _ = try await probe.probe(defaultProfile)
        let request = await transport.capturedRequest
        #expect(request?.httpShouldHandleCookies == false)
    }

    @Test("Probe targets the correct capabilities URL for the hosted profile")
    func requestURLForHosted() async throws {
        let fixtureData = try canonicalCapabilitiesData()
        let expectedURL = defaultProfile.capabilitiesURL()
        let transport = RecordingTransport(
            data: fixtureData,
            response: makeHTTPResponse(status: 200, url: expectedURL)
        )
        let probe = CapabilityProbe(transport: transport)
        _ = try await probe.probe(defaultProfile)
        let request = await transport.capturedRequest
        #expect(request?.url == expectedURL)
    }

    @Test("Probe targets the correct URL for a custom server with non-default port and path prefix")
    func requestURLForCustomPortAndPath() async throws {
        let profile = try ServerProfile.custom(
            displayName: "Self-hosted",
            rawURL: "http://localhost:9000/myapp"
        )
        let expectedURL = profile.capabilitiesURL()
        let fixtureData = try canonicalCapabilitiesData()
        let transport = RecordingTransport(
            data: fixtureData,
            response: makeHTTPResponse(status: 200, url: expectedURL)
        )
        let probe = CapabilityProbe(transport: transport)
        _ = try await probe.probe(profile)
        let request = await transport.capturedRequest
        #expect(request?.url?.absoluteString == "http://localhost:9000/myapp/api/v1/capabilities")
    }

    @Test("An injected evaluator pin also determines the request path")
    func requestURLUsesEvaluatorPin() async throws {
        let pin = ContractPin(
            backendCommit: "test",
            supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 11),
            minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 11),
            expectedApiBasePath: "/api/v2",
            sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
        )
        let expectedURL = defaultProfile.capabilitiesURL(pin: pin)
        let transport = try RecordingTransport(
            data: canonicalCapabilitiesData(),
            response: makeHTTPResponse(status: 200, url: expectedURL)
        )
        let probe = CapabilityProbe(
            transport: transport,
            evaluator: CompatibilityEvaluator(pin: pin)
        )

        _ = try await probe.probe(defaultProfile)

        let request = await transport.capturedRequest
        #expect(request?.url == expectedURL)
    }
}
