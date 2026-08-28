@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("HTTPTransport")
struct HTTPTransportTests {
    @Test("The production session delegate refuses redirects")
    func productionTransportRefusesRedirects() async throws {
        let origin = try #require(URL(string: "https://origin.example/authenticate"))
        let destination = try #require(URL(string: "https://attacker.example/collect"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        let response = try #require(
            HTTPURLResponse(
                url: origin,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        let redirectedRequest = URLRequest(url: destination)
        let delegate = RedirectRejectingURLSessionDelegate()

        let acceptedRequest = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: redirectedRequest
            ) { request in
                continuation.resume(returning: request)
            }
        }

        #expect(acceptedRequest == nil)
    }
}
