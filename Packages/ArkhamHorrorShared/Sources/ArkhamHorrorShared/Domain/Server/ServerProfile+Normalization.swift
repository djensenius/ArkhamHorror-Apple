import Foundation

// MARK: - URL normalisation helpers

/// URL validation and normalization helpers backing ``ServerProfile``'s canonical
/// factories (see `ServerProfile.swift`). Centralizing parsing here — rather than in
/// any UI or network layer — is what lets every downstream consumer (sign-in,
/// register, whoami, capability probe, and the profile editor) reuse a single,
/// already-validated ``ServerProfile/baseURL`` instead of re-parsing or duplicating
/// scheme/host/loopback/port rules.
extension ServerProfile {
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
    ///
    /// Plain `http` is rejected unless the host is the local loopback interface (see
    /// ``isLoopbackHost(_:)``): credentials and tokens must never be sent over an
    /// insecure channel to anything but the local device, and this is the one, narrow,
    /// unambiguous exception that keeps local development servers usable.
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
        let normalizedHost = host.lowercased()
        if scheme == "http", !isLoopbackHost(normalizedHost) {
            throw ServerProfileError.insecureScheme
        }
        return (scheme, normalizedHost)
    }

    /// Whether `host` (already lowercased) refers only to the local loopback
    /// interface, using a strict, unambiguous check rather than any platform's
    /// numeric-address parsing — which can treat hex, octal, or short-form addresses
    /// (e.g. `0x7f000001`, `017700000001`, or `127.1`) as loopback in ways this
    /// validator must not replicate.
    ///
    /// Exactly three forms qualify: the literal hostname `localhost` (no subdomain
    /// such as `localhost.example.com` and no lookalike such as `localhost.evil.com`
    /// qualifies), the strict four-segment decimal dotted-quad form of an IPv4 address
    /// whose first octet is `127`, and the IPv6 loopback address `::1` — `host` may
    /// carry the bracketed literal form (`[::1]`), since that is how
    /// `URLComponents.host` reports an IPv6 authority.
    static func isLoopbackHost(_ host: String) -> Bool {
        let unbracketed: String = if host.hasPrefix("["), host.hasSuffix("]") {
            String(host.dropFirst().dropLast())
        } else {
            host
        }
        if unbracketed == "localhost" || unbracketed == "::1" {
            return true
        }
        return isLoopbackIPv4DottedQuad(unbracketed)
    }

    /// Whether `host` is a strict, unambiguous four-segment decimal dotted-quad IPv4
    /// address in `127.0.0.0/8`.
    ///
    /// Each segment must be either exactly `"0"` or a leading-zero-free decimal number
    /// from 1-255, so ambiguous forms that some numeric-address parsers treat as octal
    /// (e.g. a segment like `"010"`) are never accepted as loopback.
    private static func isLoopbackIPv4DottedQuad(_ host: String) -> Bool {
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 4 else { return false }
        var octets: [Int] = []
        for segment in segments {
            guard !segment.isEmpty, segment.allSatisfy(\.isNumber) else { return false }
            guard segment == "0" || !segment.hasPrefix("0") else { return false }
            guard let value = Int(segment), (0 ... 255).contains(value) else { return false }
            octets.append(value)
        }
        return octets.first == 127
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
