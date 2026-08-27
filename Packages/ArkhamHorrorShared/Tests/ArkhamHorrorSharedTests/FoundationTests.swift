@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Foundation behavior")
struct FoundationTests {
    @Test("Server URLs receive HTTPS and normalize casing and trailing slashes")
    func normalizesServerURL() throws {
        let endpoint = try ServerEndpoint("  EXAMPLE.com/api/  ")

        #expect(endpoint.url.absoluteString == "https://example.com/api")
    }

    @Test("Server URLs retain an explicit HTTP scheme")
    func retainsExplicitScheme() throws {
        let endpoint = try ServerEndpoint("http://localhost:8080/")

        #expect(endpoint.url.absoluteString == "http://localhost:8080")
    }

    @Test("Scheme-like path content still receives HTTPS")
    func ignoresSchemeLikePathContent() throws {
        let endpoint = try ServerEndpoint("example.com/cards/http://reference")

        #expect(endpoint.url.scheme == "https")
        #expect(endpoint.url.host == "example.com")
    }

    @Test("Server URLs discard embedded credentials")
    func discardsUserInfo() throws {
        let userInfo = "investigator:password"
        let endpoint = try ServerEndpoint("https://\(userInfo)@example.com")

        #expect(endpoint.url.absoluteString == "https://example.com")
    }

    @Test(
        "Invalid server URLs report domain errors",
        arguments: [
            ("", ServerEndpointError.empty),
            ("example.com@evil.com", ServerEndpointError.credentialsRequireScheme),
            ("ftp://example.com", ServerEndpointError.unsupportedScheme),
            ("https://", ServerEndpointError.missingHost),
        ]
    )
    func rejectsInvalidServerURL(input: String, expectedError: ServerEndpointError) {
        #expect(throws: expectedError) {
            try ServerEndpoint(input)
        }
    }

    @Test("Focus targets map to semantic commands")
    func mapsTargetsToCommands() {
        #expect(AppCommandTarget.serverStatus.command == .openServerConfiguration)
        #expect(AppCommandTarget.primaryAction.command == .beginNewCampaign)
    }
}
