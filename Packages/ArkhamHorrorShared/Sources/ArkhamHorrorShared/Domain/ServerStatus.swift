import Foundation

enum ServerEndpointError: Error, Equatable, Sendable {
    case empty
    case credentialsRequireScheme
    case invalidURL
    case missingHost
    case unsupportedScheme
}

struct ServerEndpoint: Equatable, Sendable {
    let url: URL

    init(_ rawValue: String) throws {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw ServerEndpointError.empty
        }

        let hasExplicitScheme = trimmedValue.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        guard hasExplicitScheme || !trimmedValue.contains("@") else {
            throw ServerEndpointError.credentialsRequireScheme
        }

        let valueWithScheme = hasExplicitScheme
            ? trimmedValue
            : "https://\(trimmedValue)"

        guard var components = URLComponents(string: valueWithScheme) else {
            throw ServerEndpointError.invalidURL
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ServerEndpointError.unsupportedScheme
        }

        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw ServerEndpointError.missingHost
        }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil

        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" {
            components.path = ""
        }

        guard let normalizedURL = components.url else {
            throw ServerEndpointError.invalidURL
        }

        url = normalizedURL
    }
}

enum ServerConnectionState: Equatable, Sendable {
    case notConfigured
    case ready
    case checking
    case online
    case offline
}

struct ServerStatus: Equatable, Sendable {
    let endpoint: ServerEndpoint?
    let connection: ServerConnectionState

    static let notConfigured = ServerStatus(endpoint: nil, connection: .notConfigured)

    var title: String {
        switch connection {
        case .notConfigured:
            "Server not configured"
        case .ready:
            "Server ready"
        case .checking:
            "Checking server"
        case .online:
            "Server online"
        case .offline:
            "Server unavailable"
        }
    }

    var detail: String {
        endpoint?.url.absoluteString ?? "A server can be connected in a later phase."
    }
}
