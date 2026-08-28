@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ServerProfile — Capabilities URL and Codable")
struct ServerProfileEncoderTests {
    // MARK: - Capabilities URL construction

    @Test("Capabilities URL for the hosted profile")
    func capabilitiesURLHosted() {
        let url = ServerProfile.hosted.capabilitiesURL()
        #expect(url.absoluteString == "https://arkhamhorror.app/api/v1/capabilities")
    }

    @Test("Capabilities URL for a root-only custom server")
    func capabilitiesURLRoot() throws {
        let profile = try ServerProfile.custom(displayName: "T", rawURL: "https://example.com")
        #expect(
            profile.capabilitiesURL().absoluteString == "https://example.com/api/v1/capabilities"
        )
    }

    @Test("Capabilities URL preserves a non-default port")
    func capabilitiesURLPreservesPort() throws {
        let profile = try ServerProfile.custom(displayName: "L", rawURL: "http://localhost:8080")
        #expect(
            profile.capabilitiesURL().absoluteString ==
                "http://localhost:8080/api/v1/capabilities"
        )
    }

    @Test("Capabilities URL appends after an existing path prefix")
    func capabilitiesURLWithPathPrefix() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com/myapp"
        )
        #expect(
            profile.capabilitiesURL().absoluteString ==
                "https://example.com/myapp/api/v1/capabilities"
        )
    }

    @Test("Capabilities URL with non-default port and path prefix")
    func capabilitiesURLPortAndPath() throws {
        let profile = try ServerProfile.custom(
            displayName: "T",
            rawURL: "https://example.com:9000/myapp"
        )
        #expect(
            profile.capabilitiesURL().absoluteString ==
                "https://example.com:9000/myapp/api/v1/capabilities"
        )
    }

    @Test("Capabilities URL uses the supplied pin's API base path")
    func capabilitiesURLCustomPin() throws {
        let pin = ContractPin(
            backendCommit: "abc",
            supportedSchemaRevision: .literal(major: 0, minor: 2, patch: 0),
            minimumServerSchemaRevision: .literal(major: 0, minor: 2, patch: 0),
            expectedApiBasePath: "/api/v2",
            sourceNativeClientMinimumRevision: .literal(major: 0, minor: 2, patch: 0)
        )
        let profile = try ServerProfile.custom(displayName: "T", rawURL: "https://example.com")
        #expect(
            profile.capabilitiesURL(pin: pin).absoluteString ==
                "https://example.com/api/v2/capabilities"
        )
    }

    // MARK: - Codable round-trip

    @Test("Custom profile survives a JSON encode/decode round-trip")
    func customProfileRoundTrip() throws {
        let profileID = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))
        let original = try ServerProfile.custom(
            id: profileID,
            displayName: "My Server",
            rawURL: "https://example.com:9000/myapp"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        #expect(decoded == original)
    }

    @Test("Hosted profile survives a JSON encode/decode round-trip")
    func hostedProfileRoundTrip() throws {
        let data = try JSONEncoder().encode(ServerProfile.hosted)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        #expect(decoded == ServerProfile.hosted)
    }

    // MARK: - API prefix mid-path rejection

    @Test("/proxy/api/v1/extra mid-path throws apiPrefixAlreadyPresent")
    func apiPrefixMidPathThrows() {
        #expect(throws: ServerProfileError.apiPrefixAlreadyPresent) {
            try ServerProfile.custom(
                displayName: "T",
                rawURL: "https://example.com/proxy/api/v1/extra"
            )
        }
    }

    // MARK: - Display name validation

    @Test("Empty display name throws emptyDisplayName")
    func emptyDisplayNameThrows() {
        #expect(throws: ServerProfileError.emptyDisplayName) {
            try ServerProfile.custom(displayName: "", rawURL: "https://example.com")
        }
    }

    @Test("Whitespace-only display name throws emptyDisplayName")
    func whitespaceDisplayNameThrows() {
        #expect(throws: ServerProfileError.emptyDisplayName) {
            try ServerProfile.custom(displayName: "   ", rawURL: "https://example.com")
        }
    }

    @Test("Display name surrounding whitespace is trimmed on creation")
    func displayNameTrimmed() throws {
        let profile = try ServerProfile.custom(
            displayName: "  My Server  ",
            rawURL: "https://example.com"
        )
        #expect(profile.displayName == "My Server")
    }

    // MARK: - Reserved ID

    @Test("Custom profile using the hosted reserved UUID throws reservedID")
    func reservedIDThrows() {
        #expect(throws: ServerProfileError.reservedID) {
            try ServerProfile.custom(
                id: ServerProfile.hosted.id,
                displayName: "T",
                rawURL: "https://example.com"
            )
        }
    }

    // MARK: - renamed(to:)

    @Test("renamed(to:) returns a new profile with updated display name")
    func renamedReturnsNewProfile() throws {
        let original = try ServerProfile.custom(
            displayName: "Old Name",
            rawURL: "https://example.com"
        )
        let renamed = try original.renamed(to: "New Name")
        #expect(renamed.displayName == "New Name")
        #expect(renamed.id == original.id)
        #expect(renamed.baseURL == original.baseURL)
        #expect(renamed.kind == original.kind)
    }

    @Test("renamed(to:) trims surrounding whitespace")
    func renamedTrimsWhitespace() throws {
        let original = try ServerProfile.custom(
            displayName: "Server",
            rawURL: "https://example.com"
        )
        let renamed = try original.renamed(to: "  New Name  ")
        #expect(renamed.displayName == "New Name")
    }

    @Test("renamed(to:) with empty string throws emptyDisplayName")
    func renamedEmptyThrows() throws {
        let profile = try ServerProfile.custom(
            displayName: "Server",
            rawURL: "https://example.com"
        )
        #expect(throws: ServerProfileError.emptyDisplayName) {
            try profile.renamed(to: "")
        }
    }

    @Test("renamed(to:) with whitespace-only string throws emptyDisplayName")
    func renamedWhitespaceThrows() throws {
        let profile = try ServerProfile.custom(
            displayName: "Server",
            rawURL: "https://example.com"
        )
        #expect(throws: ServerProfileError.emptyDisplayName) {
            try profile.renamed(to: "   ")
        }
    }

    // MARK: - Codable corruption

    @Test("Decoding a hosted profile with a wrong UUID throws a decoding error")
    func decodeHostedWrongUUIDThrows() {
        let json = """
        {
            "id": "AAAAAAAA-0000-0000-0000-000000000001",
            "displayName": "Arkham Horror Online",
            "baseURL": "https://arkhamhorror.app",
            "kind": "hosted"
        }
        """
        #expect {
            try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        } throws: { $0 is DecodingError }
    }

    @Test("Decoding a hosted profile with a wrong base URL throws a decoding error")
    func decodeHostedWrongURLThrows() {
        let canonical = ServerProfile.hosted
        let json = """
        {
            "id": "\(canonical.id.uuidString)",
            "displayName": "\(canonical.displayName)",
            "baseURL": "https://evil.example.com",
            "kind": "hosted"
        }
        """
        #expect {
            try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        } throws: { $0 is DecodingError }
    }

    @Test("Decoding a hosted profile with a wrong display name throws a decoding error")
    func decodeHostedWrongNameThrows() {
        let canonical = ServerProfile.hosted
        let json = """
        {
            "id": "\(canonical.id.uuidString)",
            "displayName": "Evil Name",
            "baseURL": "\(canonical.baseURL.absoluteString)",
            "kind": "hosted"
        }
        """
        #expect {
            try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        } throws: { $0 is DecodingError }
    }

    @Test("Decoding a custom profile with the reserved hosted UUID throws a decoding error")
    func decodeCustomWithReservedIDThrows() {
        let hostedID = ServerProfile.hosted.id.uuidString
        let json = """
        {
            "id": "\(hostedID)",
            "displayName": "My Server",
            "baseURL": "https://example.com",
            "kind": "custom"
        }
        """
        #expect {
            try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        } throws: { $0 is DecodingError }
    }

    @Test("Decoding a custom profile with an empty display name throws a decoding error")
    func decodeCustomWithEmptyNameThrows() {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789abc",
            "displayName": "   ",
            "baseURL": "https://example.com",
            "kind": "custom"
        }
        """
        #expect {
            try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        } throws: { $0 is DecodingError }
    }

    @Test("Decoding a custom profile with an /api/v1 URL throws a decoding error")
    func decodeCustomWithAPIPathThrows() {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789abc",
            "displayName": "My Server",
            "baseURL": "https://example.com/api/v1",
            "kind": "custom"
        }
        """
        #expect {
            try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        } throws: { $0 is DecodingError }
    }
}
