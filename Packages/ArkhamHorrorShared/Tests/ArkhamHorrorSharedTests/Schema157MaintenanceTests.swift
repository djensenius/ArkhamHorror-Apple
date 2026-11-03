@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 maintenance mode: every non-allow-listed route answers HTTP 503 with
/// `Retry-After: 120` and `{"maintenance": true, "since", "message"}` (backend
/// Foundation.hs `maintenanceMiddleware`, synthetic bytes below). The capability probe
/// must surface that body as a maintenance state, never "Update Required" or the generic
/// probe failure. A 503 without that body stays the generic probe failure.
@MainActor
@Suite("Schema 0.1.57 maintenance 503")
struct Schema157MaintenanceTests {
    /// Answers the capability request with a scripted HTTP response.
    private struct HookedTransport: CapabilityProbeTransport {
        let status: Int
        let headers: [String: String]?
        let body: Data

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            ))
            return (body, response)
        }
    }

    /// Synthetic: the `maintenanceMiddleware` body with the default message
    /// (Api/Arkham/Maintenance.hs `defaultMaintenanceMessage`).
    static let serverMessage = "Arkham Horror is down for scheduled database maintenance. "
        + "Games in progress are saved and will be exactly where you left them."
    static let body = Data(
        #"{"maintenance":true,"since":"2025-01-02T03:04:05Z","message":"\#(serverMessage)"}"#
            .utf8
    )

    @Test("A 503 with Retry-After and the maintenance body becomes a maintenance state")
    func maintenanceWithHeaderAndBody() async throws {
        let maintenance = ServerMaintenance(
            retryAfterSeconds: 120,
            notice: ServerMaintenanceNotice(
                since: "2025-01-02T03:04:05Z", message: Self.serverMessage
            )
        )
        try await assertProbe(
            HookedTransport(status: 503, headers: ["Retry-After": "120"], body: Self.body),
            throws: maintenance
        )
        let state = await sessionState(
            HookedTransport(status: 503, headers: ["retry-after": " 120 "], body: Self.body)
        )
        #expect(state == .unavailable(profile: .hosted, reason: .maintenance(maintenance)))
        #expect(state.title == "Server maintenance")
        #expect(state.isRetryable)
        let message = try #require(Self.reason(state)).message
        #expect(message == "\(Self.serverMessage) Try again in about 2 minutes.")
        Self.expectNotUpdateOrProbeFailure(state, message: message)
    }

    @Test("A maintenance body without a message uses the generic maintenance copy")
    func maintenanceBodyWithoutMessage() async throws {
        let state = await sessionState(HookedTransport(
            status: 503, headers: ["Retry-After": "60"], body: Data(#"{"maintenance":true}"#.utf8)
        ))
        let maintenance = ServerMaintenance(retryAfterSeconds: 60)
        #expect(state == .unavailable(profile: .hosted, reason: .maintenance(maintenance)))
        let message = try #require(Self.reason(state)).message
        #expect(message == "This server is temporarily down, most likely for maintenance. "
            + "Try again in about a minute.")
        Self.expectNotUpdateOrProbeFailure(state, message: message)
    }

    /// A 503 from an ingress, proxy or load balancer is not maintenance: it keeps the
    /// pre-0.1.57 generic probe failure, whatever its `Retry-After` says.
    @Test("A 503 without the maintenance body stays a generic probe failure")
    func nonMaintenance503IsGenericFailure() async {
        let responses: [([String: String]?, String)] = [
            (nil, ""),
            (["Retry-After": "60"], ""),
            (["Retry-After": "120"], "<html><body>503 Service Unavailable</body></html>"),
            (nil, "not json"),
            (nil, #"{"maintenance":false,"message":"x"}"#),
            (nil, #"{"maintenance":"true","message":"x"}"#),
            (nil, #"{"message":"x"}"#),
        ]
        for (headers, body) in responses {
            let state = await sessionState(
                HookedTransport(status: 503, headers: headers, body: Data(body.utf8))
            )
            #expect(
                state == .unavailable(
                    profile: .hosted, reason: .probeFailed(.unexpectedStatus(503))
                ),
                "\(String(describing: headers)) \(body)"
            )
            #expect(state.title == "Server unavailable", "\(body)")
        }
    }

    @Test("A maintenance 503 without, or with a malformed, Retry-After has no retry hint")
    func maintenanceWithoutUsableHeader() async throws {
        let headers: [[String: String]?] = [
            nil,
            ["Retry-After": ""],
            ["Retry-After": "soon"],
            ["Retry-After": "-5"],
            ["Retry-After": "1.5"],
            ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"],
            ["Retry-After": "99999999999999999999"],
            ["Retry-After": "\(ServerMaintenance.maximumRetryAfterSeconds + 1)"],
        ]
        let notice = ServerMaintenanceNotice(
            since: "2025-01-02T03:04:05Z", message: Self.serverMessage
        )
        for header in headers {
            let state = await sessionState(
                HookedTransport(status: 503, headers: header, body: Self.body)
            )
            #expect(
                state == .unavailable(
                    profile: .hosted, reason: .maintenance(.init(notice: notice))
                ),
                "\(String(describing: header))"
            )
            let message = try #require(Self.reason(state)).message
            #expect(message == "\(Self.serverMessage) Try again later.")
            Self.expectNotUpdateOrProbeFailure(state, message: message)
        }
    }

    @Test("Malformed or non-maintenance 503 bodies are not a maintenance notice")
    func malformedBodiesAreIgnored() {
        let bodies = [
            "not json",
            "[]",
            #"{"maintenance":false,"message":"x"}"#,
            #"{"maintenance":"true","message":"x"}"#,
            #"{"message":"x"}"#,
            #"{"maintenance":true,"message":"a","message":"b"}"#,
        ]
        for body in bodies {
            #expect(ServerMaintenanceNotice(body: Data(body.utf8)) == nil, "\(body)")
        }
        let partial = ServerMaintenanceNotice(
            body: Data(#"{"maintenance":true,"since":7,"message":"  "}"#.utf8)
        )
        #expect(partial == ServerMaintenanceNotice(since: nil, message: nil))
        let long = String(repeating: "x", count: 5000)
        let capped = ServerMaintenanceNotice(
            body: Data(#"{"maintenance":true,"message":"\#(long)"}"#.utf8)
        )
        #expect(capped?.message?.count == ServerMaintenanceNotice.maximumMessageLength)
    }

    @Test("Non-503 statuses keep their existing outcomes")
    func otherStatusesUnchanged() async {
        let state = await sessionState(
            HookedTransport(status: 500, headers: ["Retry-After": "120"], body: Self.body)
        )
        #expect(state == .unavailable(
            profile: .hosted, reason: .probeFailed(.unexpectedStatus(500))
        ))
    }

    private func assertProbe(
        _ transport: HookedTransport, throws expected: ServerMaintenance
    ) async throws {
        let probe = CapabilityProbe(transport: transport)
        await #expect(throws: CapabilityProbeError.maintenance(expected)) {
            try await probe.probe(.hosted)
        }
    }

    private func sessionState(_ transport: HookedTransport) async -> SessionState {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: CapabilityProbe(transport: transport),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        return model.sessionState
    }

    private static func reason(_ state: SessionState) -> SessionUnavailableReason? {
        guard case let .unavailable(_, reason) = state else { return nil }
        return reason
    }

    private static func expectNotUpdateOrProbeFailure(_ state: SessionState, message: String) {
        let genericProbeFailures = [
            SessionUnavailableReason.probeFailed(.unexpectedStatus(503)).message,
            SessionUnavailableReason.probeFailed(.transportFailure("x")).message,
        ]
        #expect(!genericProbeFailures.contains(message))
        #expect(!message.contains("needs to be updated"))
        #expect(!state.title.localizedCaseInsensitiveContains("update"))
        #expect(state.title != "Server unavailable")
        #expect(!state.detail.hasPrefix("Could not reach"))
    }
}
