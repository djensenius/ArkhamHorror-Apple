@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Unit tests for ``AssetTaskDelegate`` in isolation, mirroring how
/// `HTTPTransportTests` exercises `RedirectRejectingURLSessionDelegate`:
/// calling the delegate's `URLSessionTaskDelegate` methods directly rather
/// than driving a real network round trip.
@Suite("AssetTaskDelegate")
struct AssetTaskDelegateTests {
    @Test("Every HTTP redirect is refused, regardless of destination")
    func everyRedirectIsRefused() async throws {
        let origin =
            try #require(URL(string: "https://assets.arkhamhorror.app/img/arkham/cards/01001.avif"))
        let destination = try #require(URL(string: "https://attacker.example/collect"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        let response = try #require(
            HTTPURLResponse(
                url: origin,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        let delegate = AssetTaskDelegate()

        let acceptedRequest = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { request in
                continuation.resume(returning: request)
            }
        }
        #expect(acceptedRequest == nil)
    }

    @Test("Server-trust challenges defer to default handling (TLS validation still runs)")
    func serverTrustDefersToDefaultHandling() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let protectionSpace = URLProtectionSpace(
            host: "assets.arkhamhorror.app",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: FakeChallengeSender()
        )
        let delegate = AssetTaskDelegate()
        let task = try session
            .dataTask(with: #require(URL(string: "https://assets.arkhamhorror.app")))

        let outcome: (URLSession.AuthChallengeDisposition, URLCredential?) =
            await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session, task: task, didReceive: challenge
                ) { disposition, credential in
                    continuation.resume(returning: (disposition, credential))
                }
            }
        #expect(outcome.0 == .performDefaultHandling)
        #expect(outcome.1 == nil)
    }

    @Test(
        "Every non-server-trust challenge is denied, never supplying a credential",
        arguments: [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodNTLM,
        ]
    )
    func nonServerTrustChallengesDenied(method: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let protectionSpace = URLProtectionSpace(
            host: "assets.arkhamhorror.app",
            port: 443,
            protocol: "https",
            realm: "assets",
            authenticationMethod: method
        )
        let credential = URLCredential(
            user: "attacker-supplied",
            password: "attacker-supplied",
            persistence: .none
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: credential,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: FakeChallengeSender()
        )
        let delegate = AssetTaskDelegate()
        let task = try session
            .dataTask(with: #require(URL(string: "https://assets.arkhamhorror.app")))

        let outcome: (URLSession.AuthChallengeDisposition, URLCredential?) =
            await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session, task: task, didReceive: challenge
                ) { disposition, credential in
                    continuation.resume(returning: (disposition, credential))
                }
            }
        #expect(outcome.0 == .cancelAuthenticationChallenge)
        #expect(outcome.1 == nil)
    }
}

/// A no-op `URLAuthenticationChallengeSender`: the delegate under test never
/// calls back into it (it only ever calls the completion handler passed to
/// `urlSession(_:task:didReceive:completionHandler:)`), so every method is
/// unreachable in these tests.
private final class FakeChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
}
