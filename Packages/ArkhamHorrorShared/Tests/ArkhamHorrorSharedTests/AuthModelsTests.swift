@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Authentication domain models")
struct AuthModelsTests {
    private func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - AuthenticationCredentials

    @Test("AuthenticationCredentials encodes exactly email and password")
    func credentialsEncoding() throws {
        let credentials = AuthenticationCredentials(email: "a@example.com", password: "s3cret")
        let object = try encode(credentials)
        #expect(Set(object.keys) == ["email", "password"])
        #expect(object["email"] as? String == "a@example.com")
        #expect(object["password"] as? String == "s3cret")
    }

    @Test("AuthenticationCredentials round-trips through Codable")
    func credentialsRoundTrip() throws {
        let original = AuthenticationCredentials(email: "a@example.com", password: "pw")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuthenticationCredentials.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - RegistrationDetails

    @Test("RegistrationDetails encodes exactly email, username, and password")
    func registrationEncoding() throws {
        let details = RegistrationDetails(
            email: "a@example.com",
            username: "ashcan",
            password: "pw"
        )
        let object = try encode(details)
        #expect(Set(object.keys) == ["email", "username", "password"])
        #expect(object["username"] as? String == "ashcan")
    }

    @Test("RegistrationDetails round-trips through Codable")
    func registrationRoundTrip() throws {
        let original = RegistrationDetails(email: "a@example.com", username: "u", password: "pw")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RegistrationDetails.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - AuthToken

    @Test("AuthToken decodes the contract Token shape")
    func tokenDecoding() throws {
        let json = Data(#"{"token":"abc123"}"#.utf8)
        let decoded = try JSONDecoder().decode(AuthToken.self, from: json)
        #expect(decoded == AuthToken(token: "abc123"))
    }

    @Test("AuthToken from the token.json fixture decodes the placeholder token")
    func tokenFixtureDecoding() throws {
        let url = try #require(
            Bundle.module.url(forResource: "token", withExtension: "json", subdirectory: "Fixtures")
        )
        let decoded = try JSONDecoder().decode(AuthToken.self, from: Data(contentsOf: url))
        #expect(decoded.token == "fixture-token-not-a-real-credential")
        #expect(decoded.hasUsableContent)
    }

    @Test("AuthToken reports empty and whitespace-only tokens as unusable")
    func tokenUsability() {
        #expect(!AuthToken(token: "").hasUsableContent)
        #expect(!AuthToken(token: "   \n\t").hasUsableContent)
        #expect(AuthToken(token: "x").hasUsableContent)
    }

    // MARK: - CurrentUser

    @Test("CurrentUser decodes all required fields")
    func currentUserDecoding() throws {
        let json = Data(
            #"{"username":"u","email":"u@example.com","beta":true,"admin":false}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CurrentUser.self, from: json)
        #expect(decoded == CurrentUser(
            username: "u",
            email: "u@example.com",
            beta: true,
            admin: false
        ))
    }

    @Test("CurrentUser from the whoami.json fixture decodes correctly")
    func currentUserFixtureDecoding() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "whoami",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let decoded = try JSONDecoder().decode(CurrentUser.self, from: Data(contentsOf: url))
        #expect(decoded == CurrentUser(
            username: "investigator",
            email: "investigator@example.com",
            beta: true,
            admin: false
        ))
    }

    @Test("CurrentUser decoding fails when a required field is missing")
    func currentUserMissingFieldFails() {
        let json = Data(#"{"username":"u","email":"u@example.com","beta":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CurrentUser.self, from: json)
        }
    }

    @Test("CurrentUser decoding fails when a field has the wrong type")
    func currentUserWrongTypeFails() {
        let json = Data(
            #"{"username":"u","email":"u@example.com","beta":"yes","admin":false}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CurrentUser.self, from: json)
        }
    }
}
