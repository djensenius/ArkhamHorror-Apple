@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `ServerProfileTests` (which was approaching SwiftLint's type body
/// length limit) purely to keep each suite's file a manageable size; these tests
/// cover `ServerProfile.endpointSummary`'s display formatting only.
@Suite("ServerProfile endpoint summary")
struct ServerProfileEndpointSummaryTests {
    @Test("Endpoint summary includes host without a trailing slash for a root path")
    func endpointSummaryDropsRootTrailingSlash() {
        #expect(ServerProfile.hosted.endpointSummary == "https://arkhamhorror.app")
    }

    @Test("Endpoint summary distinguishes profiles that differ only by port")
    func endpointSummaryDistinguishesPort() throws {
        let lowPort = try ServerProfile.custom(
            displayName: "A", rawURL: "https://example.com:8080"
        )
        let highPort = try ServerProfile.custom(
            displayName: "B", rawURL: "https://example.com:9090"
        )
        #expect(lowPort.endpointSummary != highPort.endpointSummary)
        #expect(lowPort.endpointSummary.hasSuffix(":8080"))
        #expect(highPort.endpointSummary.hasSuffix(":9090"))
    }

    @Test("Endpoint summary distinguishes profiles that differ only by path")
    func endpointSummaryDistinguishesPath() throws {
        let tenantA = try ServerProfile.custom(
            displayName: "A", rawURL: "https://example.com/TenantA"
        )
        let tenantB = try ServerProfile.custom(
            displayName: "B", rawURL: "https://example.com/TenantB"
        )
        #expect(tenantA.endpointSummary != tenantB.endpointSummary)
        #expect(tenantA.endpointSummary.hasSuffix("/TenantA"))
        #expect(tenantB.endpointSummary.hasSuffix("/TenantB"))
    }

    @Test("Endpoint summary distinguishes loopback profiles that differ only by scheme")
    func endpointSummaryDistinguishesScheme() throws {
        let http = try ServerProfile.custom(displayName: "A", rawURL: "http://localhost:8080")
        let https = try ServerProfile.custom(displayName: "B", rawURL: "https://localhost:8080")
        #expect(http.endpointSummary != https.endpointSummary)
        #expect(http.endpointSummary.hasPrefix("http://"))
        #expect(https.endpointSummary.hasPrefix("https://"))
    }
}
