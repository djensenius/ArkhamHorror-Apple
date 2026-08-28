import Foundation

/// Probes the capabilities endpoint derived from the compiled-in contract pin and
/// evaluates the response against that pin.
///
/// The probe is injectable via ``CapabilityProbeTransport``, which allows deterministic
/// unit testing without real network calls.
///
/// TLS certificate validation is never bypassed. No authentication credentials or
/// cookies are sent to this public endpoint. ``URLSessionTransport`` uses a dedicated
/// ephemeral session to enforce this at the session level; the request also sets
/// `httpShouldHandleCookies = false` as a defence-in-depth measure for injected transports.
struct CapabilityProbe: Sendable {
    private let transport: any CapabilityProbeTransport
    private let evaluator: CompatibilityEvaluator

    /// Creates a probe backed by a dedicated ephemeral, credential-free transport and the
    /// current contract pin.
    init() {
        transport = URLSessionTransport()
        evaluator = CompatibilityEvaluator(pin: .current)
    }

    /// Creates a probe with an injectable transport and evaluator for testing.
    init(
        transport: any CapabilityProbeTransport,
        evaluator: CompatibilityEvaluator = CompatibilityEvaluator(pin: .current)
    ) {
        self.transport = transport
        self.evaluator = evaluator
    }

    /// Probes the server described by `profile` and returns the compatibility outcome.
    ///
    /// Sends `GET <baseURL><pin.expectedApiBasePath>/capabilities` with
    /// `Accept: application/json`.
    ///
    /// | Server response                      | Result                                          |
    /// |--------------------------------------|-------------------------------------------------|
    /// | HTTP 200–299 valid JSON              | `CompatibilityEvaluator.evaluate(_:)` outcome   |
    /// | HTTP 200–299 invalid JSON            | throws `CapabilityProbeError.malformedPayload`  |
    /// | HTTP 404                             | `CompatibilityOutcome.legacyFallback`           |
    /// | Other HTTP status                    | throws `CapabilityProbeError.unexpectedStatus`  |
    /// | Non-HTTP response                    | throws `CapabilityProbeError.nonHTTPResponse`   |
    /// | Genuine transport failure            | throws `CapabilityProbeError.transportFailure`  |
    /// | `CancellationError` / task cancelled | rethrows `CancellationError`                    |
    ///
    /// Cooperative cancellation is preserved: a `CancellationError` thrown by the
    /// transport is rethrown directly, and `Task.checkCancellation()` is called before
    /// wrapping any other transport error so that a `URLError.cancelled` produced by a
    /// cancelled `URLSession` task surfaces as `CancellationError` when the enclosing
    /// Swift task is cancelled.
    func probe(_ profile: ServerProfile) async throws -> CompatibilityOutcome {
        let url = profile.capabilitiesURL(pin: evaluator.pin)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as CapabilityProbeError {
            throw error
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Rethrow as CancellationError when the enclosing task is cancelled,
            // so URLError.cancelled emitted by URLSession under cancellation is not
            // misreported as a generic transport failure.
            try Task.checkCancellation()
            throw CapabilityProbeError.transportFailure(String(describing: error))
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CapabilityProbeError.nonHTTPResponse
        }

        switch httpResponse.statusCode {
        case 200 ... 299:
            do {
                let capabilities = try JSONDecoder().decode(ServerCapabilities.self, from: data)
                return evaluator.evaluate(capabilities)
            } catch {
                throw CapabilityProbeError.malformedPayload(String(describing: error))
            }
        case 404:
            return evaluator.legacyFallback()
        default:
            throw CapabilityProbeError.unexpectedStatus(httpResponse.statusCode)
        }
    }
}
