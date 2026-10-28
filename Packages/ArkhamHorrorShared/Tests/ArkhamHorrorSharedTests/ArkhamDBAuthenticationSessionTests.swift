#if os(macOS)
    import AppKit
    @testable import ArkhamHorrorShared
    import AuthenticationServices
    import Testing

    @Suite("Native ArkhamDB authentication lifecycle", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ArkhamDBAuthenticationSessionTests {
        @Test("Start uses the sheet's exact anchor and returns the callback")
        func successfulStart() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            let task = await harness.begin()
            let native = try #require(harness.sessions.first)
            #expect(harness.urls == [harness.authorizationURL])
            #expect(native.startCount == 1)
            let provider = try #require(harness.context)
            let probe = ASWebAuthenticationSession(
                url: harness.authorizationURL, callbackURLScheme: nil
            ) { _, _ in }
            #expect(provider.presentationAnchor(for: probe) === harness.window)
            harness.authentication.updatePresentationAnchor(harness.window)
            #expect(native.cancelCount == 0)
            let completion = native.completion
            let callback = harness.callbackURL
            await Task.detached { completion(callback, nil) }.value
            #expect(try await task.value == harness.callbackURL)
            #expect(native.cancelCount == 0)
            // The local provider above deliberately keeps this first context alive.
            try await harness.expectSubsequentSuccess()
        }

        @Test("Missing or hidden owned windows never fall back to another open window")
        func unavailablePresenter() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            harness.authentication.updatePresentationAnchor(nil)
            await #expect(throws: ArkhamDBLinkFlowError.presentationUnavailable) {
                try await harness.authentication.authenticate(url: harness.authorizationURL)
            }
            harness.authentication.updatePresentationAnchor(harness.window)
            harness.window.orderOut(nil)
            await #expect(throws: ArkhamDBLinkFlowError.presentationUnavailable) {
                try await harness.authentication.authenticate(url: harness.authorizationURL)
            }
            #expect(harness.sessions.isEmpty)
            harness.window.orderFrontRegardless()
            try await harness.expectSubsequentSuccess()
        }

        @Test("Native start failure cancels and cleans up before a later attempt")
        func startFailure() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            harness.startResult = false
            let task = await harness.begin()
            await #expect(throws: ArkhamDBLinkFlowError.failed) { try await task.value }
            #expect(harness.sessions.first?.cancelCount == 1)
            #expect(harness.context == nil)
            harness.startResult = true
            try await harness.expectSubsequentSuccess(stale: harness.sessions.first?.completion)
        }

        @Test("An inline native start callback is fenced even when start returns false")
        func inlineStartCallback() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            harness.startResult = false
            harness.completesOnStart = true
            let task = await harness.begin()
            await #expect(throws: ArkhamDBLinkFlowError.failed) { try await task.value }
            #expect(harness.context == nil)
            #expect(harness.sessions[0].cancelCount == 1)
            harness.startResult = true
            try await harness.expectSubsequentSuccess(stale: harness.sessions[0].completion)
        }

        @Test("Native errors and empty callbacks permit retry", arguments: [0, 1, 2])
        func callbackFailure(kind: Int) async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            let task = await harness.begin()
            let native = try #require(harness.sessions.first)
            let error: (any Error)? = switch kind {
            case 0: ASWebAuthenticationSessionError(.canceledLogin)
            case 1: ASWebAuthenticationSessionError(.presentationContextInvalid)
            default: nil
            }
            native.completion(nil, error)
            if kind == 0 {
                await #expect(throws: CancellationError.self) { try await task.value }
            } else {
                await #expect(throws: ArkhamDBLinkFlowError.failed) { try await task.value }
            }
            #expect(native.cancelCount == 0)
            #expect(harness.context == nil)
            native.completion(harness.callbackURL, nil)
            try await harness.expectSubsequentSuccess()
        }

        @Test("Task cancellation cancels native auth once; late callbacks cannot finish a retry")
        func taskCancellation() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            let task = await harness.begin()
            let native = try #require(harness.sessions.first)
            // Simulate a native cancel() implementation that calls its completion inline.
            native.onCancel = { native.completion(harness.callbackURL, nil) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            native.onCancel = {}
            #expect(native.cancelCount == 1)
            #expect(harness.context == nil)
            try await harness.expectSubsequentSuccess(stale: native.completion)
        }

        @Test("A pre-cancelled task does not construct or start a native session")
        func cancelledBeforeStart() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            let task = Task {
                try await harness.authentication.authenticate(url: harness.authorizationURL)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(harness.sessions.isEmpty)
            try await harness.expectSubsequentSuccess()
        }

        @Test("Concurrent authenticate is rejected without disturbing the current attempt")
        func concurrentAttempts() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            let task = await harness.begin()
            await #expect(throws: ArkhamDBLinkFlowError.failed) {
                try await harness.authentication.authenticate(url: harness.authorizationURL)
            }
            #expect(harness.sessions.count == 1)
            harness.sessions[0].completion(harness.callbackURL, nil)
            #expect(try await task.value == harness.callbackURL)
            #expect(harness.context == nil)
            try await harness.expectSubsequentSuccess(stale: harness.sessions[0].completion)
        }

        @Test("Detaching or replacing the owned presenter cancels auth with an honest error")
        func presenterChanged() async throws {
            let harness = AuthenticationHarness()
            defer { harness.close() }
            let view = ArkhamDBAnchorView()
            view.onChange = { [weak authentication = harness.authentication] in
                authentication?.updatePresentationAnchor($0)
            }
            harness.window.contentView?.addSubview(view)
            let task = await harness.begin()
            let native = try #require(harness.sessions.first)
            view.removeFromSuperview()
            await #expect(throws: ArkhamDBLinkFlowError.presentationUnavailable) {
                try await task.value
            }
            #expect(native.cancelCount == 1)
            #expect(harness.context == nil)
            await #expect(throws: ArkhamDBLinkFlowError.presentationUnavailable) {
                try await harness.authentication.authenticate(url: harness.authorizationURL)
            }
            harness.window.contentView?.addSubview(view)
            try await harness.expectSubsequentSuccess(stale: native.completion)
            // A move directly to a different window must invalidate the old anchor too.
            let next = await harness.begin()
            let other = AuthenticationHarness.makeWindow()
            defer { other.close() }
            harness.authentication.updatePresentationAnchor(other)
            await #expect(throws: ArkhamDBLinkFlowError.presentationUnavailable) {
                try await next.value
            }
            try await harness.expectSubsequentSuccess()
        }

        @Test("Completion releases native session and wrapper without a retain cycle")
        func releasesReferences() async throws {
            var harness: AuthenticationHarness? = AuthenticationHarness()
            weak var authentication: ArkhamDBAuthenticationSession?
            authentication = harness?.authentication
            weak var native: StubNativeAuthenticationSession?
            if let current = harness {
                let task = await current.begin()
                native = current.sessions.first
                native?.completion(current.callbackURL, nil)
                #expect(try await task.value == current.callbackURL)
                #expect(current.context == nil)
                current.sessions.removeAll()
                #expect(native == nil)
                current.close()
            }
            harness = nil
            #expect(authentication == nil)
        }
    }

    @MainActor
    private final class AuthenticationHarness {
        let window = makeWindow()
        let authorizationURL = URL(string: "https://arkhamdb.example/authorize")!
        let callbackURL = URL(string: "arkhamhorror://arkhamdb-link?result=pending&completion=new")!
        var startResult = true
        var completesOnStart = false
        var sessions: [StubNativeAuthenticationSession] = []
        var urls: [URL] = []
        weak var context: (any ASWebAuthenticationPresentationContextProviding)?
        private let starts = AsyncStream<Void>.makeStream()
        lazy var authentication = ArkhamDBAuthenticationSession { [unowned self] url, ctx, reply in
            context = ctx
            urls.append(url)
            let native = StubNativeAuthenticationSession(
                startResult: startResult, completion: reply,
                onStart: { [starts, completesOnStart, callbackURL] in
                    starts.continuation.yield()
                    if completesOnStart {
                        reply(callbackURL, nil)
                    }
                }
            )
            sessions.append(native)
            return native
        }

        init() {
            authentication.updatePresentationAnchor(window)
        }

        static func makeWindow() -> NSWindow {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }

        func begin() async -> Task<URL, any Error> {
            let task = Task { try await authentication.authenticate(url: authorizationURL) }
            var iterator = starts.stream.makeAsyncIterator()
            _ = await iterator.next()
            return task
        }

        func expectSubsequentSuccess(
            stale: (@Sendable (URL?, (any Error)?) -> Void)? = nil
        ) async throws {
            let task = await begin()
            let native = try #require(sessions.last)
            let oldURL = URL(string: "arkhamhorror://arkhamdb-link?result=pending&completion=old")!
            stale?(oldURL, nil)
            native.completion(callbackURL, nil)
            native.completion(oldURL, nil)
            #expect(try await task.value == callbackURL)
            #expect(context == nil)
            #expect(native.cancelCount == 0)
        }

        func close() {
            authentication.updatePresentationAnchor(nil)
            starts.continuation.finish()
            window.close()
        }
    }

    @MainActor
    private final class StubNativeAuthenticationSession: ArkhamDBNativeAuthenticationSession {
        let startResult: Bool
        let completion: @Sendable (URL?, (any Error)?) -> Void
        let onStart: () -> Void
        var onCancel: () -> Void = {}
        var startCount = 0
        var cancelCount = 0

        init(
            startResult: Bool,
            completion: @escaping @Sendable (URL?, (any Error)?) -> Void,
            onStart: @escaping () -> Void
        ) {
            self.startResult = startResult
            self.completion = completion
            self.onStart = onStart
        }

        func start() -> Bool {
            startCount += 1
            onStart()
            return startResult
        }

        func cancel() {
            cancelCount += 1
            onCancel()
        }
    }
#endif
