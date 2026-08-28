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
    ///   `http` is accepted only for the local loopback interface (`localhost`, a
    ///   dotted-decimal `127.0.0.0/8` address, or `::1`); every other host — including
    ///   a LAN address, a public host, or a `localhost` lookalike/subdomain — must use
    ///   `https`, since credentials and tokens are never sent over plain HTTP to
    ///   anything but the local device.
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
