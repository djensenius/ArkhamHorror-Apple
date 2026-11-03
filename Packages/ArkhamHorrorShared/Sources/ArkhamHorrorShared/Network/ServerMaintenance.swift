import Foundation

/// A server-wide maintenance window, reported as HTTP 503 by every non-allow-listed
/// route (backend Foundation.hs `maintenanceMiddleware`): `Retry-After: 120` plus the
/// body `{"maintenance": true, "since": <UTCTime>, "message": <Text>}`.
///
/// Only a 503 whose body is that maintenance object maps here. Any other 503 (for
/// example from an ingress or proxy) stays a generic probe failure. `Retry-After` and
/// the body's `since`/`message` are parsed defensively and are optional.
struct ServerMaintenance: Equatable, Sendable {
    /// Seconds from `Retry-After`, when it is a plain non-negative integer of at most a
    /// week. An HTTP-date or any other value is ignored.
    let retryAfterSeconds: Int?
    /// The body: a JSON object with `"maintenance": true`.
    let notice: ServerMaintenanceNotice

    static let maximumRetryAfterSeconds = 7 * 24 * 60 * 60

    init(retryAfterSeconds: Int? = nil, notice: ServerMaintenanceNotice = .init()) {
        self.retryAfterSeconds = retryAfterSeconds
        self.notice = notice
    }

    /// `nil` unless `body` is the maintenance object.
    init?(response: HTTPURLResponse, body: Data) {
        guard let notice = ServerMaintenanceNotice(body: body) else { return nil }
        self.init(
            retryAfterSeconds: Self.retryAfterSeconds(
                response.value(forHTTPHeaderField: "Retry-After")
            ),
            notice: notice
        )
    }

    static func retryAfterSeconds(_ header: String?) -> Int? {
        guard let value = header?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value.count <= 9,
              value.unicodeScalars.allSatisfy({ ("0" ... "9").contains($0) }),
              let seconds = Int(value),
              seconds <= maximumRetryAfterSeconds
        else { return nil }
        return seconds
    }
}

/// The optional maintenance 503 body. Only `"maintenance": true` is required; `since`
/// and `message` are kept when they are strings, and a blank message is dropped.
struct ServerMaintenanceNotice: Equatable, Sendable {
    static let maximumMessageLength = 1000

    let since: String?
    let message: String?

    init(since: String? = nil, message: String? = nil) {
        self.since = since
        self.message = message
    }

    init?(body: Data) {
        guard !body.isEmpty,
              case let .object(object)? = try? LosslessJSONParser.parse(body),
              object["maintenance"] == .bool(true)
        else { return nil }
        if case let .string(since)? = object["since"] {
            self.since = since
        } else {
            since = nil
        }
        if case let .string(message)? = object["message"] {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            self.message = trimmed.isEmpty
                ? nil
                : String(trimmed.prefix(Self.maximumMessageLength))
        } else {
            message = nil
        }
    }
}

extension ServerMaintenance {
    /// A user-facing explanation: the server's own message when it sent one, otherwise a
    /// generic maintenance line, followed by when to try again.
    var message: String {
        let reason = notice.message
            ?? "This server is temporarily down, most likely for maintenance."
        guard let retryAfterSeconds else {
            return "\(reason) Try again later."
        }
        let minutes = max(1, (retryAfterSeconds + 59) / 60)
        let wait = minutes == 1 ? "about a minute" : "about \(minutes) minutes"
        return "\(reason) Try again in \(wait)."
    }
}
