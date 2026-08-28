import Foundation

/// A narrow transport interface for capability probe network calls.
///
/// This is a semantic refinement of ``HTTPTransport`` scoped to the public capabilities
/// endpoint. The production implementation is ``URLSessionTransport``. Tests supply a stub
/// or failing conformance to exercise all probe code paths without real network I/O.
///
/// Implementations must not bypass TLS certificate validation and must not inject
/// authentication credentials; the capabilities endpoint is public.
protocol CapabilityProbeTransport: HTTPTransport {}

/// ``URLSessionTransport`` also satisfies the probe-specific transport marker so the
/// public capability probe can reuse the single shared, credential-free session.
extension URLSessionTransport: CapabilityProbeTransport {}
