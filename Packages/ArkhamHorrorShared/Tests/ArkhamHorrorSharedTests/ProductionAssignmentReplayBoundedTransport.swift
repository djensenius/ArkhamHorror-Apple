@testable import ArkhamHorrorShared
import Foundation

enum AssignmentReplayBoundedTransportError: Error, Equatable {
    case responseTooLarge
}

struct AssignmentReplayBoundedHTTPTransport: HTTPTransport {
    private let configuration: URLSessionConfiguration
    private let maxByteCount: Int
    private let deadline: AssignmentReplayCoordinatorDeadline?
    private let timeout: TimeInterval

    init(
        maxByteCount: Int,
        deadline: AssignmentReplayCoordinatorDeadline
    ) throws {
        try self.init(
            maxByteCount: maxByteCount,
            timeout: deadline.remainingSeconds(),
            deadline: deadline
        )
    }

    init(maxByteCount: Int, timeout: TimeInterval) throws {
        try self.init(
            maxByteCount: maxByteCount,
            timeout: timeout,
            deadline: nil,
            protocolClasses: nil
        )
    }

    init(
        maxByteCount: Int,
        timeout: TimeInterval,
        protocolClasses: [AnyClass]
    ) throws {
        try self.init(
            maxByteCount: maxByteCount,
            timeout: timeout,
            deadline: nil,
            protocolClasses: protocolClasses
        )
    }

    private init(
        maxByteCount: Int,
        timeout: TimeInterval,
        deadline: AssignmentReplayCoordinatorDeadline?,
        protocolClasses: [AnyClass]? = nil
    ) throws {
        guard maxByteCount > 0,
              timeout.isFinite,
              timeout > 0,
              timeout <=
              ProductionAssignmentReplayConfiguration.maximumDeadlineSeconds
        else {
            throw ProductionAssignmentReplayCoordinatorError.deadlineExpired
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy =
            .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [:]
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        self.configuration = configuration
        self.maxByteCount = maxByteCount
        self.deadline = deadline
        self.timeout = timeout
    }

    func data(for originalRequest: URLRequest) async throws -> (
        Data,
        URLResponse
    ) {
        var request = originalRequest
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = try requestTimeout()

        return try await AssignmentReplayBoundedDataLoader(
            maxByteCount: maxByteCount
        ).load(
            request: request,
            configuration: configuration
        )
    }

    private func requestTimeout() throws -> TimeInterval {
        if let deadline {
            return try deadline.remainingSeconds()
        }
        return timeout
    }
}

// swiftlint:disable opening_brace
private final class AssignmentReplayBoundedDataLoader:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let maxByteCount: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation:
        CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var data = Data()
    private var cancelled = false

    init(maxByteCount: Int) {
        self.maxByteCount = maxByteCount
    }

    func load(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard response.expectedContentLength <= Int64(maxByteCount) else {
            finish(
                with: .failure(
                    AssignmentReplayBoundedTransportError.responseTooLarge
                ),
                cancellingTask: true
            )
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = response
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(Int(response.expectedContentLength), maxByteCount)
            )
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive incomingData: Data
    ) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        let isTooLarge =
            incomingData.count > maxByteCount - data.count
        if !isTooLarge {
            data.append(incomingData)
        }
        lock.unlock()
        guard isTooLarge else { return }
        finish(
            with: .failure(
                AssignmentReplayBoundedTransportError.responseTooLarge
            ),
            cancellingTask: true
        )
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(with: .failure(error))
            return
        }

        lock.lock()
        let response = response
        let data = data
        lock.unlock()
        guard let response else {
            finish(
                with: .failure(URLError(.badServerResponse))
            )
            return
        }
        finish(with: .success((data, response)))
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(
            with: .failure(CancellationError()),
            cancellingTask: true
        )
    }

    private func finish(
        with result: Result<(Data, URLResponse), Error>,
        cancellingTask: Bool = false
    ) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let task = task
        self.task = nil
        let session = session
        self.session = nil
        lock.unlock()

        if cancellingTask {
            task?.cancel()
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation.resume(with: result)
    }
}

// swiftlint:enable opening_brace
