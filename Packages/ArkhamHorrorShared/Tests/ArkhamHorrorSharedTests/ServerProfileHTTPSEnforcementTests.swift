@testable import ArkhamHorrorShared
import Foundation
import Testing

/// HTTPS enforcement and the loopback-only HTTP exception: production UI must never
/// send credentials or tokens over plaintext HTTP, so ``ServerProfile`` validation
/// (see `ServerProfile+Normalization.swift`) rejects any non-loopback HTTP origin
/// while still permitting local development against `localhost`/`127.0.0.0/8`/`::1`.
/// See `ServerProfileTests.swift` for the companion coverage of general URL
/// validation/normalization not specific to scheme security.
extension ServerProfileTests {
    // MARK: - HTTPS enforcement / loopback-only HTTP exception

    @Test(
        "HTTP is accepted only for the strict loopback interface",
        arguments: [
            "http://localhost",
            "http://localhost:8080",
            "http://127.0.0.1",
            "http://127.0.0.1:9000",
            "http://127.1.1.1",
            "http://127.255.255.255",
            "http://[::1]",
            "http://[::1]:8080",
        ]
    )
    func loopbackHTTPAccepted(rawURL: String) throws {
        let profile = try ServerProfile.custom(displayName: "L", rawURL: rawURL)
        #expect(profile.baseURL.scheme == "http")
    }

    @Test(
        "HTTP to any non-loopback host (LAN, public, or a localhost lookalike) throws",
        arguments: [
            // LAN addresses.
            "http://192.168.1.10",
            "http://10.0.0.5",
            // A public host.
            "http://example.com",
            // Loopback-adjacent but not loopback: 127.0.0.0/8's the only exempt
            // range, and this is a different octet entirely.
            "http://128.0.0.1",
            // `localhost` subdomains/lookalikes must not inherit the exception.
            "http://localhost.evil.com",
            "http://evil-localhost.com",
            "http://notlocalhost",
            // Ambiguous numeric forms some parsers treat as loopback must not be
            // accepted by this validator's strict dotted-quad check.
            "http://127.1",
            "http://0x7f000001",
            "http://017700000001",
            "http://2130706433",
        ]
    )
    func nonLoopbackHTTPThrowsInsecureScheme(rawURL: String) {
        #expect(throws: ServerProfileError.insecureScheme) {
            try ServerProfile.custom(displayName: "T", rawURL: rawURL)
        }
    }

    @Test("A dotted-quad octet with a leading zero is rejected rather than treated as loopback")
    func leadingZeroOctetRejectedAsLoopback() {
        #expect(throws: ServerProfileError.insecureScheme) {
            try ServerProfile.custom(displayName: "T", rawURL: "http://127.0.010.1")
        }
    }

    @Test("HTTPS is always accepted regardless of host, including loopback")
    func httpsAcceptedForAnyHost() throws {
        let publicProfile = try ServerProfile.custom(
            displayName: "T", rawURL: "https://example.com"
        )
        #expect(publicProfile.baseURL.scheme == "https")
        let loopbackProfile = try ServerProfile.custom(
            displayName: "L", rawURL: "https://localhost:8443"
        )
        #expect(loopbackProfile.baseURL.scheme == "https")
    }

    @Test("Persisted JSON with an insecure non-loopback HTTP base URL fails to decode")
    func decodingInsecureHTTPBaseURLThrows() throws {
        // Build valid JSON by encoding a real profile, then downgrade only the
        // baseURL's scheme in place, so this test does not need to know the exact
        // (Codable-synthesized) shape of the `kind` field.
        let profile = try ServerProfile.custom(displayName: "Evil", rawURL: "https://example.com")
        let encodedData = try JSONEncoder().encode(profile)
        let encoded = try #require(String(data: encodedData, encoding: .utf8))
        let downgraded = encoded.replacingOccurrences(
            of: "https:\\/\\/example.com", with: "http:\\/\\/example.com"
        )
        let decoder = JSONDecoder()
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ServerProfile.self, from: Data(downgraded.utf8))
        }
    }

    @Test("Persisted JSON with a loopback HTTP base URL decodes successfully")
    func decodingLoopbackHTTPBaseURLSucceeds() throws {
        let profile = try ServerProfile.custom(
            displayName: "Local", rawURL: "https://localhost:8080"
        )
        let encodedData = try JSONEncoder().encode(profile)
        let encoded = try #require(String(data: encodedData, encoding: .utf8))
        let downgraded = encoded.replacingOccurrences(
            of: "https:\\/\\/localhost", with: "http:\\/\\/localhost"
        )
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ServerProfile.self, from: Data(downgraded.utf8))
        #expect(decoded.baseURL.scheme == "http")
        #expect(decoded.baseURL.host == "localhost")
    }
}
