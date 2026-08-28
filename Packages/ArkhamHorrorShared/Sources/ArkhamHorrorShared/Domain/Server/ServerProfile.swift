import Foundation

/// Identifies the role and hosting context of a ``ServerProfile``.
enum ServerProfileKind: Equatable, Hashable, Sendable, Codable {
    /// The canonical hosted `arkhamhorror.app` service.
    case hosted
    /// A user-configured self-hosted or local server.
    case custom
}

/// A stored server configuration for connecting to an Arkham Horror game server.
///
/// All construction goes through ``ServerProfile/hosted`` or
/// ``ServerProfile/custom(id:displayName:rawURL:)``; the raw initializer is private
/// to ensure every instance satisfies the URL and display-name invariants.
///
/// Credentials and authentication tokens are never stored in a profile.
struct ServerProfile: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identity across edits and persistence round-trips.
    let id: UUID
    /// User-visible label for this server. Always non-empty and whitespace-trimmed.
    ///
    /// Use ``renamed(to:)`` to obtain a new profile with a different name.
    let displayName: String
    /// Validated, normalized server root URL.
    ///
    /// Never contains the API path prefix reserved by the current ``ContractPin``;
    /// use ``capabilitiesURL(pin:)`` to build the full endpoint URL.
    let baseURL: URL
    /// Hosting context for this profile.
    let kind: ServerProfileKind

    private init(id: UUID, displayName: String, baseURL: URL, kind: ServerProfileKind) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.kind = kind
    }
}

// MARK: - Factory

extension ServerProfile {
    /// The canonical hosted Arkham Horror service profile.
    ///
    /// The production domain `arkhamhorror.app` follows the backend deployment
    /// configuration. Update this canonical profile if the hosted domain changes.
    static let hosted: ServerProfile = {
        guard
            let hostedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            let hostedURL = URL(string: "https://arkhamhorror.app")
        else {
            preconditionFailure("Hosted profile literal values are compile-time valid")
        }
        return ServerProfile(
            id: hostedID,
            displayName: "Arkham Horror Online",
            baseURL: hostedURL,
            kind: .hosted
        )
    }()

    /// Creates a validated custom server profile from user-supplied URL input.
    ///
    /// Validation rules:
    /// - `id` must not equal ``ServerProfile/hosted``'s reserved UUID.
    /// - `displayName` must not be empty or whitespace-only; surrounding whitespace
    ///   is trimmed.
    /// - `rawURL` must not be empty. Only `https` and `http` schemes are accepted.
    ///   Both are permitted for self-hosted and local servers.
    /// - A non-empty host is required.
    /// - Credentials (`user@host`, `user:pass@host`), fragments, and query strings
    ///   are rejected.
    /// - The path must not contain the API segment sequence reserved by the current
    ///   ``ContractPin``; the client appends that prefix automatically.
    /// - Non-default ports and explicit path prefixes are preserved.
    ///
    /// A missing scheme defaults to `https`.
    ///
    /// - Throws: ``ServerProfileError`` describing the first validation failure.
    static func custom(
        id: UUID = UUID(),
        displayName: String,
        rawURL: String
    ) throws -> ServerProfile {
        guard id != ServerProfile.hosted.id else {
            throw ServerProfileError.reservedID
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ServerProfileError.emptyDisplayName
        }
        let url = try normalizedBaseURL(rawURL)
        return ServerProfile(id: id, displayName: trimmedName, baseURL: url, kind: .custom)
    }

    /// Returns a copy of this profile with a new display name.
    ///
    /// Surrounding whitespace in `newName` is trimmed.
    /// - Throws: ``ServerProfileError/emptyDisplayName`` when `newName` is empty or
    ///   whitespace-only after trimming.
    func renamed(to newName: String) throws -> ServerProfile {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerProfileError.emptyDisplayName
        }
        return ServerProfile(id: id, displayName: trimmed, baseURL: baseURL, kind: kind)
    }
}

// MARK: - Capabilities URL

extension ServerProfile {
    /// Constructs a pin-derived API endpoint URL for this profile.
    ///
    /// Appends `<pin.expectedApiBasePath><path>` to ``baseURL``'s existing path so a
    /// profile with a path prefix (e.g. `https://example.com/myapp`) correctly preserves
    /// that prefix before the pin-derived API path.
    ///
    /// - Parameters:
    ///   - path: The endpoint path relative to the API base path, including its leading
    ///     slash (e.g. `"/authenticate"`).
    ///   - pin: The contract pin whose `expectedApiBasePath` prefixes the endpoint.
    func endpointURL(path: String, pin: ContractPin = .current) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure(
                "baseURL \(baseURL) is a pre-validated URL; URLComponents must succeed"
            )
        }
        components.path = baseURL.path + pin.expectedApiBasePath + path
        guard let url = components.url else {
            preconditionFailure(
                "Endpoint URL construction from pre-validated baseURL must succeed"
            )
        }
        return url
    }

    /// Constructs the capabilities endpoint URL for this profile.
    ///
    /// Appends `<pin.expectedApiBasePath>/capabilities` to ``baseURL``'s existing path
    /// so a profile with a path prefix (e.g. `https://example.com/myapp`) correctly
    /// preserves that prefix before the pin-derived capabilities path.
    func capabilitiesURL(pin: ContractPin = .current) -> URL {
        endpointURL(path: "/capabilities", pin: pin)
    }
}

// MARK: - Codable

private extension ServerProfile {
    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case kind
    }
}

extension ServerProfile: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(baseURL.absoluteString, forKey: .baseURL)
        try container.encode(kind, forKey: .kind)
    }
}

/// Explicit ``Decodable`` implementation that enforces profile invariants on decode.
///
/// - For `.hosted` profiles: all decoded fields must exactly match the canonical
///   ``ServerProfile/hosted`` constant; any deviation is a decoding failure.
/// - For `.custom` profiles: the URL is re-validated through the same rules as
///   ``ServerProfile/custom(id:displayName:rawURL:)``, and the reserved hosted UUID
///   is rejected.
extension ServerProfile: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let decodedName = try container.decode(String.self, forKey: .displayName)
        let urlString = try container.decode(String.self, forKey: .baseURL)
        let decodedKind = try container.decode(ServerProfileKind.self, forKey: .kind)

        switch decodedKind {
        case .hosted:
            let canonical = ServerProfile.hosted
            guard
                decodedID == canonical.id,
                decodedName == canonical.displayName,
                urlString == canonical.baseURL.absoluteString
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Hosted profile data does not match the canonical constant"
                )
            }
            self = canonical

        case .custom:
            guard decodedID != ServerProfile.hosted.id else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Custom profile may not use the reserved hosted UUID"
                )
            }
            let trimmedName = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .displayName,
                    in: container,
                    debugDescription: "Display name must not be empty or whitespace-only"
                )
            }
            let url: URL
            do {
                url = try ServerProfile.normalizedBaseURL(urlString)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .baseURL,
                    in: container,
                    debugDescription: "Invalid base URL '\(urlString)': \(error)"
                )
            }
            self.init(id: decodedID, displayName: trimmedName, baseURL: url, kind: .custom)
        }
    }
}

// MARK: - URL normalisation helpers

private extension ServerProfile {
    /// Validates, normalizes, and returns a base URL from raw user input.
    ///
    /// `apiBasePath` defaults to `ContractPin.current.expectedApiBasePath` so that
    /// validation stays in sync with the compiled-in contract pin rather than hard-coding
    /// a specific version string.
    static func normalizedBaseURL(
        _ rawValue: String,
        apiBasePath: String = ContractPin.current.expectedApiBasePath
    ) throws -> URL {
        let withScheme = try withExplicitScheme(rawValue)
        guard var components = URLComponents(string: withScheme) else {
            throw ServerProfileError.malformedURL
        }
        try assertNoForbiddenComponents(components)
        let (scheme, host) = try validatedSchemeAndHost(components)
        guard let schemeSeparator = withScheme.range(of: "://") else {
            throw ServerProfileError.malformedURL
        }
        let authority = withScheme[schemeSeparator.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":") else {
            throw ServerProfileError.malformedURL
        }
        let portRange = (components as NSURLComponents).rangeOfPort
        if portRange.location != NSNotFound {
            guard let port = components.port, (1 ... 65535).contains(port) else {
                throw ServerProfileError.malformedURL
            }
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.query = nil
        components.path = try normalizedPath(components.path, apiBasePath: apiBasePath)
        guard let url = components.url else {
            throw ServerProfileError.malformedURL
        }
        return url
    }

    /// Trims whitespace, rejects credentials in scheme-less authority, and prepends
    /// `https://` when no explicit scheme is present.
    static func withExplicitScheme(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerProfileError.emptyURL
        }
        let hasExplicitScheme = trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        let lowercased = trimmed.lowercased()
        let hasMalformedSupportedScheme =
            !hasExplicitScheme &&
            (lowercased.hasPrefix("http:") || lowercased.hasPrefix("https:"))
        if hasMalformedSupportedScheme {
            throw ServerProfileError.malformedURL
        }
        if !hasExplicitScheme {
            let authority = trimmed.prefix { !"/?#".contains($0) }
            if authority.contains("@") {
                throw ServerProfileError.credentialsNotAllowed
            }
        }
        return hasExplicitScheme ? trimmed : "https://\(trimmed)"
    }

    /// Throws if `components` contains any fragment, query, or credential fields.
    static func assertNoForbiddenComponents(_ components: URLComponents) throws {
        guard components.fragment == nil else {
            throw ServerProfileError.fragmentNotAllowed
        }
        guard components.query == nil else {
            throw ServerProfileError.queryNotAllowed
        }
        guard components.user == nil, components.password == nil else {
            throw ServerProfileError.credentialsNotAllowed
        }
    }

    /// Returns the lowercased scheme and host, throwing for unsupported or absent values.
    static func validatedSchemeAndHost(
        _ components: URLComponents
    ) throws -> (scheme: String, host: String) {
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http" else {
            throw ServerProfileError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw ServerProfileError.missingHost
        }
        return (scheme, host.lowercased())
    }

    /// Strips trailing slashes and rejects paths that contain the current API base-path
    /// segment sequence (derived from ``ContractPin/expectedApiBasePath``), including
    /// mid-path occurrences such as `/proxy/<basePath>/extra`.
    ///
    /// Similar-but-distinct segments such as `/api/v10` (when the base path is `/api/v1`)
    /// are allowed because the trailing-slash/hasSuffix check enforces segment boundaries.
    static func normalizedPath(_ rawPath: String, apiBasePath: String) throws -> String {
        var path = rawPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        let lower = path.lowercased()
        let lowerPrefix = apiBasePath.lowercased()
        if lower.contains(lowerPrefix + "/") || lower.hasSuffix(lowerPrefix) {
            throw ServerProfileError.apiPrefixAlreadyPresent
        }
        return path
    }
}
