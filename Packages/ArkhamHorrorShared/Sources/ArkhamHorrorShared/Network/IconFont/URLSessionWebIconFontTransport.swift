import Foundation

struct URLSessionWebIconFontTransport: WebIconFontTransporting {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        var configuration = URLSessionConfiguration.ephemeral
        Self.harden(&configuration, timeout: timeout)
        session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    init(configuration: URLSessionConfiguration, timeout: TimeInterval = 15) {
        var configuration = configuration
        Self.harden(&configuration, timeout: timeout)
        session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    private static func harden(
        _ configuration: inout URLSessionConfiguration,
        timeout: TimeInterval
    ) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
    }

    func fetch(
        _ request: WebIconFontHTTPRequest,
        maxBytes: Int
    ) async throws -> WebIconFontHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(
            "font/ttf, font/woff2, application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        if let ifNoneMatch = request.ifNoneMatch {
            urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let ifModifiedSince = request.ifModifiedSince {
            urlRequest.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: urlRequest)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw WebIconFontFailure.transportFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw WebIconFontFailure.transportFailure
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        guard http.statusCode == 200 else {
            stream.task.cancel()
            return WebIconFontHTTPResponse(
                statusCode: http.statusCode, etag: etag, lastModified: lastModified, data: Data()
            )
        }
        if http.expectedContentLength > Int64(maxBytes) {
            stream.task.cancel()
            throw WebIconFontFailure.tooLarge
        }
        let data = try await Self.readBounded(stream, maxBytes: maxBytes)
        return WebIconFontHTTPResponse(
            statusCode: http.statusCode,
            etag: etag,
            lastModified: lastModified,
            data: data
        )
    }

    private static func readBounded(
        _ stream: URLSession.AsyncBytes,
        maxBytes: Int
    ) async throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maxBytes, 64 * 1024))
        do {
            for try await byte in stream {
                guard bytes.count < maxBytes else {
                    stream.task.cancel()
                    throw WebIconFontFailure.tooLarge
                }
                bytes.append(byte)
            }
        } catch let failure as WebIconFontFailure {
            throw failure
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw WebIconFontFailure.transportFailure
        }
        try Task.checkCancellation()
        return Data(bytes)
    }
}
