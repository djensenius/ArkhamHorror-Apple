@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB link safety")
struct ArkhamDBLinkSafetyTests {
    @Test("Completion secrets encode on the wire but never describe or reflect their contents")
    func secretRedaction() throws {
        let secret = try ArkhamDBCompletionSecret("single-use-private-value")
        let request = ArkhamDBLinkCompletionRequest(completion: secret)
        #expect(try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(request)) ==
            .object(["completion": .string("single-use-private-value")]))
        var output = ""
        dump(request, to: &output)
        for rendered in [
            String(describing: request),
            String(reflecting: request),
            String(describing: secret),
            String(reflecting: secret),
            output,
        ] {
            #expect(!rendered.contains(secret.rawValue))
        }
        #expect(Mirror(reflecting: request).children.isEmpty)
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test("Direct import construction rejects invalid remote IDs before any request")
    func importValidation() throws {
        #expect(try ArkhamDBImportRequest(deckId: "00123").deckId == "00123")
        for invalid in ["", "-1", "12.0", "١٢٣", "123/path", " 123"] {
            #expect(throws: ArkhamDBImportRequest.ValidationError.invalidDeckID) {
                try ArkhamDBImportRequest(deckId: invalid)
            }
        }
    }

    @Test("Only absolute HTTPS authorization URLs may open the browser")
    func authorizationURLValidation() throws {
        let valid = ArkhamDBLinkStartResponse(authorizeUrl: "https://arkhamdb.example/auth?state=x", expiresAt: "later")
        #expect(try valid.authorizationURL().absoluteString == valid.authorizeUrl)
        for invalid in [
            "http://arkhamdb.example/auth",
            "javascript:alert(1)",
            "arkhamhorror://auth",
            "/relative",
            "https:",
            "not a URL",
        ] {
            let response = ArkhamDBLinkStartResponse(authorizeUrl: invalid, expiresAt: "later")
            #expect(throws: ArkhamDBLinkFlowError.invalidAuthorizationURL) {
                try response.authorizationURL()
            }
        }
    }

    @Test("Callback parsing enforces the scheme, host, pending result and unique nonempty secret")
    func invalidCallbacks() throws {
        let valid = try ArkhamDBLinkCompletionRequest(callback: #require(URL(
            string: "arkhamhorror://arkhamdb-link?result=pending&completion=secret%2Bvalue"
        )))
        #expect(valid.completion.rawValue == "secret+value")
        for invalid in [
            "https://arkhamdb-link?result=pending&completion=s",
            "arkhamhorror://other?result=pending&completion=s",
            "arkhamhorror://arkhamdb-link/path?result=pending&completion=s",
            "arkhamhorror://arkhamdb-link?result=success&completion=s",
            "arkhamhorror://arkhamdb-link?result=pending",
            "arkhamhorror://arkhamdb-link?result=pending&completion=",
            "arkhamhorror://arkhamdb-link?result=pending&completion=a&completion=b",
            "arkhamhorror://arkhamdb-link?result=pending&result=pending&completion=s",
        ] {
            let url = try #require(URL(string: invalid))
            #expect(throws: ArkhamDBLinkFlowError.invalidCallback) {
                try ArkhamDBLinkCompletionRequest(callback: url)
            }
        }
    }

    @Test("Future server error codes round trip without confusing app session expiry")
    func unknownErrorCode() throws {
        let data = Data(#"{"code":"futureCode","error":"server detail"}"#.utf8)
        let error = try ContractJSON.decode(ArkhamDBError.self, from: data)
        #expect(error.code == .unknown("futureCode"))
        #expect(!error.requiresRelinking)
        #expect(try ContractJSON.decode(ArkhamDBError.self, from: ContractJSON.encode(error)) == error)
    }
}
