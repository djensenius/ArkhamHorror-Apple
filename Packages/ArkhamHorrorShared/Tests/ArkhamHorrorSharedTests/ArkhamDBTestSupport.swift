@testable import ArkhamHorrorShared
import Foundation
import Testing

actor ArkhamDBScriptedTransport: HTTPTransport {
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, Data)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw TestFailure() }
        let (status, data) = responses.removeFirst()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        ))
        return (data, response)
    }
}

func arkhamDBFixtureData(_ key: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "arkhamdb", withExtension: "json", subdirectory: "Fixtures/Contract"
    ))
    let root = try ContractJSON.decode([String: JSONValue].self, from: Data(contentsOf: url))
    return try ContractJSON.encode(#require(root[key]))
}

func arkhamDBFixture<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
    try ContractJSON.decode(type, from: arkhamDBFixtureData(key))
}

let arkhamDBTestContext = DeckRequestContext(
    token: "app-token", sessionGeneration: 1, credentialEpoch: 0, globalEpoch: 0
)
