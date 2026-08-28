@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ServerProfile")
struct ServerProfileTests {
    // MARK: - Hosted constant

    @Test("Hosted profile has the infrastructure-derived base URL and correct kind")
    func hostedProfileURL() {
        let profile = ServerProfile.hosted
        #expect(profile.baseURL.absoluteString == "https://arkhamhorror.app")
        #expect(profile.kind == .hosted)
    }

    @Test("Hosted profile has a non-empty display name")
    func hostedProfileDisplayName() {
        #expect(!ServerProfile.hosted.displayName.isEmpty)
    }

    @Test("Hosted profile has a stable identity across multiple accesses")
    func hostedProfileStableID() {
        #expect(ServerProfile.hosted.id == ServerProfile.hosted.id)
    }

    // MARK: - URL normalization

    @Test("Missing scheme defaults to HTTPS")
    func defaultsToHTTPS() throws {
        let profile = try ServerProfile.custom(displayName: "T", rawURL: "example.com")
        #expect(profile.baseURL.scheme == "https")
    }

    @Test("Explicit HTTPS is preserved")
    func preservesHTTPS() throws {
        let profile = try ServerProfile.custom(displayName: "T", rawURL: "https://example.com")
        #expect(profile.baseURL.scheme == "https")
    }

    @Test("Explicit HTTP is accepted for local servers")
    func acceptsHTTP() throws {
        let profile = try ServerProfile.custom(displayName: "L", rawURL: "http://localhost:8080")
        #expect(profile.baseURL.scheme == "http")
        #expect(profile.baseURL.host == "localhost")
    }

    @Test("Non-default port is preserved")
    func preservesPort() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com:9000"
        )
        #expect(profile.baseURL.port == 9000)
    }

    @Test("Explicit path prefix is preserved")
    func preservesPathPrefix() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com/myapp"
        )
        #expect(profile.baseURL.path == "/myapp")
    }

    @Test("Trailing slash is stripped from the base URL")
    func stripsTrailingSlash() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com/myapp/"
        )
        #expect(profile.baseURL.absoluteString == "https://example.com/myapp")
    }

    @Test("Host is normalised to lowercase")
    func lowercasesHost() throws {
        let profile = try ServerProfile.custom(displayName: "T", rawURL: "https://EXAMPLE.COM")
        #expect(profile.baseURL.host == "example.com")
    }

    @Test("Leading and trailing whitespace is trimmed")
    func trimsWhitespace() throws {
        let profile = try ServerProfile.custom(displayName: "T", rawURL: "  example.com  ")
        #expect(profile.baseURL.scheme == "https")
        #expect(profile.baseURL.host == "example.com")
    }

    @Test("At-sign in a path segment is allowed (not treated as credentials)")
    func atSignInPathAllowed() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com/@me/api"
        )
        #expect(profile.baseURL.absoluteString == "https://example.com/@me/api")
    }

    // MARK: - Validation errors

    @Test("Empty string throws emptyURL")
    func emptyURLThrows() {
        #expect(throws: ServerProfileError.emptyURL) {
            try ServerProfile.custom(displayName: "T", rawURL: "")
        }
    }

    @Test("Whitespace-only string throws emptyURL")
    func whitespaceOnlyThrows() {
        #expect(throws: ServerProfileError.emptyURL) {
            try ServerProfile.custom(displayName: "T", rawURL: "   ")
        }
    }

    @Test("Scheme-less URL with user@host throws credentialsNotAllowed")
    func schemelessCredentialsThrow() {
        #expect(throws: ServerProfileError.credentialsNotAllowed) {
            try ServerProfile.custom(displayName: "T", rawURL: "user@example.com")
        }
    }

    @Test("HTTPS URL with user:pass@host throws credentialsNotAllowed")
    func httpsCredentialsThrow() {
        #expect(throws: ServerProfileError.credentialsNotAllowed) {
            try ServerProfile.custom(displayName: "T", rawURL: "https://user:pass@example.com")
        }
    }

    @Test("Unsupported scheme throws unsupportedScheme")
    func unsupportedSchemeThrows() {
        #expect(throws: ServerProfileError.unsupportedScheme) {
            try ServerProfile.custom(displayName: "T", rawURL: "ftp://example.com")
        }
    }

    @Test(
        "Malformed HTTP or HTTPS scheme is rejected instead of treated as a host",
        arguments: ["http:/localhost", "https:example.com"]
    )
    func malformedSupportedSchemeThrows(rawURL: String) {
        #expect(throws: ServerProfileError.malformedURL) {
            try ServerProfile.custom(displayName: "T", rawURL: rawURL)
        }
    }

    @Test(
        "Out-of-range ports throw instead of terminating URL normalization",
        arguments: ["https://example.com:0", "https://example.com:65536"]
    )
    func outOfRangePortThrows(rawURL: String) {
        #expect(throws: ServerProfileError.malformedURL) {
            try ServerProfile.custom(displayName: "T", rawURL: rawURL)
        }
    }

    @Test("URL with only scheme and no host throws missingHost")
    func missingHostThrows() {
        #expect(throws: ServerProfileError.missingHost) {
            try ServerProfile.custom(displayName: "T", rawURL: "https://")
        }
    }

    @Test("URL with fragment throws fragmentNotAllowed")
    func fragmentThrows() {
        #expect(throws: ServerProfileError.fragmentNotAllowed) {
            try ServerProfile.custom(displayName: "T", rawURL: "https://example.com#section")
        }
    }

    @Test("URL with query string throws queryNotAllowed")
    func queryThrows() {
        #expect(throws: ServerProfileError.queryNotAllowed) {
            try ServerProfile.custom(displayName: "T", rawURL: "https://example.com?key=val")
        }
    }

    @Test("URL whose path is exactly /api/v1 throws apiPrefixAlreadyPresent")
    func apiPrefixRootThrows() {
        #expect(throws: ServerProfileError.apiPrefixAlreadyPresent) {
            try ServerProfile.custom(displayName: "T", rawURL: "https://example.com/api/v1")
        }
    }

    @Test("URL whose path ends with /api/v1 under a prefix throws apiPrefixAlreadyPresent")
    func apiPrefixUnderPathThrows() {
        #expect(throws: ServerProfileError.apiPrefixAlreadyPresent) {
            try ServerProfile.custom(
                displayName: "T",
                rawURL: "https://example.com/myapp/api/v1"
            )
        }
    }

    @Test("/api/v10 is not the API prefix and is accepted")
    func apiV10NotPrefixAllowed() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com/api/v10"
        )
        #expect(profile.baseURL.path == "/api/v10")
    }

    @Test("/api/v1 with trailing slash throws apiPrefixAlreadyPresent after normalisation")
    func apiPrefixWithTrailingSlashThrows() {
        #expect(throws: ServerProfileError.apiPrefixAlreadyPresent) {
            try ServerProfile.custom(displayName: "T", rawURL: "https://example.com/api/v1/")
        }
    }

    @Test("URL containing ContractPin.current.expectedApiBasePath throws apiPrefixAlreadyPresent")
    func apiPrefixFromCurrentPinThrows() {
        // Builds the rejected URL from the live pin so the test exercises the validator
        // when the pin advances to a new API version.
        let basePath = ContractPin.current.expectedApiBasePath
        #expect(throws: ServerProfileError.apiPrefixAlreadyPresent) {
            try ServerProfile.custom(
                displayName: "T",
                rawURL: "https://example.com\(basePath)"
            )
        }
    }

    @Test("URL with ContractPin base path mid-path throws apiPrefixAlreadyPresent")
    func apiPrefixFromCurrentPinMidPathThrows() {
        let basePath = ContractPin.current.expectedApiBasePath
        #expect(throws: ServerProfileError.apiPrefixAlreadyPresent) {
            try ServerProfile.custom(
                displayName: "T",
                rawURL: "https://example.com/proxy\(basePath)/extra"
            )
        }
    }
}
