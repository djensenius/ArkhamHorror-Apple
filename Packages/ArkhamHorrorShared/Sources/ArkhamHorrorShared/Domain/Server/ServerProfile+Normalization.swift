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
        guard let schemeSeparator = withScheme.range(of: "://") else {
            throw ServerProfileError.malformedURL
        }
        let rawScheme = withScheme[..<schemeSeparator.lowerBound].lowercased()
        let authority = withScheme[schemeSeparator.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":") else {
            throw ServerProfileError.malformedURL
        }
        // Validated against the raw, literal authority text — before `URLComponents`
        // ever sees it — so Foundation's own percent-decoding, IDNA normalization, or
        // numeric-host canonicalization can never turn a non-loopback-looking authority
        // (a percent-escaped `local%68ost`, full-width dots, a circled-letter lookalike,
        // and so on) into something that only *resolves to* an accepted loopback form
        // after being processed. See ``assertStrictLoopbackAuthority(_:)``.
        if rawScheme == "http" {
            try assertStrictLoopbackAuthority(authority)
        }

        guard var components = URLComponents(string: withScheme) else {
            throw ServerProfileError.malformedURL
        }
        try assertNoForbiddenComponents(components)
        let (scheme, host) = try validatedSchemeAndHost(components)
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
        // An explicit port that merely repeats the scheme's default (443 for https, 80
        // for the loopback-only http exception) is canonicalized away: endpoint
        // identity and duplicate-profile detection must treat `https://host:443/path`
        // and `https://host/path` as the same server, and editing between the two
        // forms must retain the existing token rather than being treated as an
        // endpoint change. Any non-default port is preserved exactly as supplied.
        if let port = components.port, isDefaultPort(port, forScheme: scheme) {
            components.port = nil
        }
        guard let url = components.url else {
            throw ServerProfileError.malformedURL
        }
        return url
    }

    private static func isDefaultPort(_ port: Int, forScheme scheme: String) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
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

    /// Validates that `rawAuthority` — the literal authority substring exactly as the
    /// caller typed it, taken immediately after a confirmed-`http` scheme's `://`
    /// separator and before any `URLComponents`/`URL` construction — is one of exactly
    /// three strict, unambiguous loopback forms, entirely in unescaped ASCII.
    ///
    /// This must run *before* `URLComponents` ever parses the string: Foundation's own
    /// percent-decoding, IDNA normalization, or numeric-host canonicalization could
    /// otherwise turn an authority that does not *look* like an accepted loopback form
    /// into one that *resolves to* an accepted form only after being processed (for
    /// example `local%68ost` decoding to `localhost`, `127%2e0%2e0%2e1` decoding to
    /// `127.0.0.1`, a full-width-dot `127。0。0。1`, or circled-letter lookalikes of
    /// `localhost`). Requiring an exact, already-ASCII, never-percent-escaped literal
    /// match here closes that gap entirely rather than relying on any downstream
    /// re-inspection of an already-normalized value.
    ///
    /// Accepts only: the case-insensitive ASCII literal `localhost`; a strict
    /// four-segment decimal dotted-quad IPv4 address in `127.0.0.0/8` with no leading
    /// zeros (see ``isLoopbackIPv4DottedQuad(_:)``); or the bracketed IPv6 loopback
    /// literal `[::1]` — each optionally followed by `:<port>`, with `<port>` itself
    /// required to be a plain ASCII decimal integer in `1...65535`. Every other form —
    /// including any percent escape, any non-ASCII byte, userinfo, control characters,
    /// a trailing-dot or subdomain/lookalike host, an ambiguous or non-canonical IPv4
    /// form, or any IPv6 form other than the exact bracketed `::1` literal (mapped,
    /// expanded, scoped, or otherwise) — is rejected.
    static func assertStrictLoopbackAuthority(_ rawAuthority: Substring) throws {
        guard rawAuthority.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw ServerProfileError.insecureScheme
        }
        guard !rawAuthority.contains("@") else {
            throw ServerProfileError.credentialsNotAllowed
        }
        guard !rawAuthority.contains("%") else {
            throw ServerProfileError.insecureScheme
        }
        guard !rawAuthority.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw ServerProfileError.malformedURL
        }

        let (rawHost, rawPort) = try splitRawHostPort(rawAuthority)
        if let rawPort {
            guard !rawPort.isEmpty, rawPort.allSatisfy(\.isASCII), rawPort.allSatisfy(\.isNumber)
            else {
                throw ServerProfileError.malformedURL
            }
            guard let port = Int(rawPort), (1 ... 65535).contains(port) else {
                throw ServerProfileError.malformedURL
            }
        }

        guard isStrictLoopbackLiteral(rawHost) else {
            throw ServerProfileError.insecureScheme
        }
    }

    /// Splits a raw (pre-`URLComponents`) authority into its host and optional port
    /// substrings, honoring the bracketed IPv6 host form. Throws for any authority
    /// this validator cannot unambiguously split, rather than guessing.
    private static func splitRawHostPort(
        _ authority: Substring
    ) throws -> (host: Substring, port: Substring?) {
        if authority.hasPrefix("[") {
            guard let closeBracket = authority.firstIndex(of: "]") else {
                throw ServerProfileError.malformedURL
            }
            let host = authority[...closeBracket]
            let afterBracket = authority[authority.index(after: closeBracket)...]
            if afterBracket.isEmpty {
                return (host, nil)
            }
            guard afterBracket.first == ":" else {
                throw ServerProfileError.malformedURL
            }
            return (host, afterBracket.dropFirst())
        }
        let colonCount = authority.count { $0 == ":" }
        guard colonCount <= 1 else {
            // An unbracketed authority with more than one colon can only be a
            // malformed authority or an unbracketed IPv6 literal; loopback IPv6 must
            // use the bracketed `[::1]` form, so this can never be a strict-loopback
            // match either way.
            throw ServerProfileError.malformedURL
        }
        if let colonIndex = authority.firstIndex(of: ":") {
            return (authority[..<colonIndex], authority[authority.index(after: colonIndex)...])
        }
        return (authority, nil)
    }

    /// Whether the raw (not percent-decoded, not IDNA-normalized) host literal exactly
    /// matches one of the three accepted loopback forms.
    private static func isStrictLoopbackLiteral(_ host: Substring) -> Bool {
        if host.hasPrefix("["), host.hasSuffix("]") {
            return host.dropFirst().dropLast() == "::1"
        }
        if host.lowercased() == "localhost" {
            return true
        }
        return isLoopbackIPv4DottedQuad(String(host))
    }

    /// Returns the lowercased scheme and host, throwing for unsupported or absent values.
    ///
    /// Plain `http` is rejected unless the host is the local loopback interface (see
    /// ``isLoopbackHost(_:)``): credentials and tokens must never be sent over an
    /// insecure channel to anything but the local device, and this is the one, narrow,
    /// unambiguous exception that keeps local development servers usable. This is a
    /// secondary, defense-in-depth check: the primary, security-critical enforcement of
    /// the loopback-only rule happens earlier, against the raw pre-`URLComponents`
    /// authority text, in ``assertStrictLoopbackAuthority(_:)``.
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
