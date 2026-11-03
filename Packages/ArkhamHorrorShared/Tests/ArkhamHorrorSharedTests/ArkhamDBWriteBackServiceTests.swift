@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB write-back service")
struct ArkhamDBWriteBackServiceTests {
    private let deckID = DeckID(UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000017")!)
    private let base = "/api/v1/arkham/arkhamdb/decks/abcdef00-0000-0000-0000-000000000017"

    private func statesData() throws -> Data {
        try ContractJSON.encode(arkhamDBWriteBackFixture("states"))
    }

    private func expectedStates() throws -> [ArkhamDBWriteBackStatus] {
        try ContractJSON.decode([ArkhamDBWriteBackStatus].self, from: statesData())
    }

    private func body(_ request: URLRequest?) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: #require(request?.httpBody))
    }

    @Test("Toggle sends PUT write-back with the exact body and decodes every owned status")
    func toggle() async throws {
        let transport = try ArkhamDBScriptedTransport([(200, statesData()), (200, statesData())])
        let service = ArkhamDBService(transport: transport)
        let enabled = try await service.setWriteBack(
            deckID: deckID, enabled: true, on: .hosted, token: "token"
        )
        #expect(try enabled == expectedStates())
        #expect(enabled.count == 8)
        _ = try await service.setWriteBack(
            deckID: deckID, enabled: false, on: .hosted, token: "token"
        )
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "PUT"])
        #expect(requests.map { $0.url?.path } == ["\(base)/write-back", "\(base)/write-back"])
        #expect(try body(requests.first) == arkhamDBWriteBackFixture("toggleRequest"))
        #expect(requests.last?.httpBody == Data(#"{"enabled":false}"#.utf8))
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token token")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test("Retry sends a bodyless POST to write-back/retry and decodes the list")
    func retry() async throws {
        let transport = try ArkhamDBScriptedTransport([(200, statesData())])
        let result = try await ArkhamDBService(transport: transport).retryWriteBack(
            deckID: deckID, on: .hosted, token: "token"
        )
        #expect(result.map(\.state).first == .succeeded)
        #expect(result.compactMap(\.conflict).count == 5)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "\(base)/write-back/retry")
        #expect(request.httpBody == nil)
    }

    @Test(
        "Each resolution posts exactly the governed request body",
        arguments: ArkhamDBWriteBackResolution.allCases
    )
    func resolve(resolution: ArkhamDBWriteBackResolution) async throws {
        let confirmed = resolution.requiresConfirmation
        let key = "\(resolution.rawValue)Request"
        let transport = try ArkhamDBScriptedTransport([(200, statesData())])
        let result = try await ArkhamDBService(transport: transport).resolveConflict(
            deckID: deckID,
            resolution: resolution,
            confirmed: confirmed,
            on: .hosted,
            token: "token"
        )
        #expect(try result == expectedStates())
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "\(base)/resolve-conflict")
        let fixture = try arkhamDBWriteBackFixture(key)
        #expect(try request.httpBody == (ContractJSON.encode(fixture)))
        #expect(try body(request) == fixture)
    }

    @Test(
        "Unconfirmed overwrite and save-as-new are refused locally without a request",
        arguments: [ArkhamDBWriteBackResolution.overwrite, .saveAsNew]
    )
    func unconfirmed(resolution: ArkhamDBWriteBackResolution) async throws {
        let transport = try ArkhamDBScriptedTransport([(200, statesData())])
        await #expect(throws: ArkhamDBResolveConflictRequest.ValidationError.confirmationRequired) {
            try await ArkhamDBService(transport: transport).resolveConflict(
                deckID: deckID,
                resolution: resolution,
                confirmed: false,
                on: .hosted,
                token: "token"
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        let status: Int
        let body: String
        let expected: DeckServiceError

        var testDescription: String {
            "HTTP \(status)"
        }
    }

    private static let disabled = ArkhamDBError(
        code: .writeBackDisabled,
        error: "Deck write-back is disabled"
    )
    private static let conflict = ArkhamDBError(
        code: .conflict,
        error: "No resolvable push; retry uncertain work before overwriting"
    )

    static let errorCases: [ErrorCase] = [
        ErrorCase(
            status: 400,
            body: "Explicit confirmation required",
            expected: .arkhamDB(ArkhamDBError(
                code: .validationFailed, error: "ArkhamDB write-back request was rejected"
            ))
        ),
        ErrorCase(status: 404, body: "", expected: .arkhamDB(ArkhamDBError(
            code: .notFound, error: "ArkhamDB deck link was not found"
        ))),
        ErrorCase(
            status: 409,
            body: #"{"code":"writeBackDisabled","error":"Deck write-back is disabled"}"#,
            expected: .arkhamDB(disabled)
        ),
        ErrorCase(
            status: 409,
            body: #"{"code":"conflict","error":"\#(conflict.error)"}"#,
            expected: .arkhamDB(conflict)
        ),
        ErrorCase(status: 409, body: "not JSON", expected: .arkhamDB(nil)),
        ErrorCase(
            status: 501,
            body: #"{"code":"disabled","error":"off"}"#,
            expected: .arkhamDB(ArkhamDBError(code: .disabled, error: "off"))
        ),
    ]

    @Test(
        "400, 404, 409 and 501 map to typed ArkhamDB errors, never session expiry",
        arguments: errorCases
    )
    func errorMapping(item: ErrorCase) async throws {
        let (status, expected) = (item.status, item.expected)
        let response = (status, Data(item.body.utf8))
        let service = ArkhamDBService(
            transport: ArkhamDBScriptedTransport(Array(repeating: response, count: 3))
        )
        await #expect(throws: expected) {
            try await service.setWriteBack(
                deckID: deckID, enabled: true, on: .hosted, token: "valid"
            )
        }
        await #expect(throws: expected) {
            try await service.retryWriteBack(deckID: deckID, on: .hosted, token: "valid")
        }
        await #expect(throws: expected) {
            try await service.resolveConflict(
                deckID: deckID, resolution: .keepRemote, confirmed: false,
                on: .hosted, token: "valid"
            )
        }
        #expect(expected != .sessionExpired)
        if case let .arkhamDB(remote) = expected {
            #expect(remote?.requiresRelinking != true)
        }
    }

    @Test("A mutation response with any unreadable row is a payload failure, not a partial list")
    func strictMutationList() async throws {
        let rows = try arkhamDBWriteBackStateRows()
        let transport = try ArkhamDBScriptedTransport([
            (200, ContractJSON.encode(JSONValue.array([rows[0], .null]))),
            (200, Data("{}".utf8)),
        ])
        let service = ArkhamDBService(transport: transport)
        await #expect(throws: DeckServiceError.malformedPayload) {
            try await service.retryWriteBack(deckID: deckID, on: .hosted, token: "token")
        }
        await #expect(throws: DeckServiceError.malformedPayload) {
            try await service.retryWriteBack(deckID: deckID, on: .hosted, token: "token")
        }
    }
}
