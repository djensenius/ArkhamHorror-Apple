import Foundation

/// The `localeCatalog` pointer a server publishes in `GET /api/v1/capabilities`.
///
/// This object carries no narrative text at all. It binds catalog state to one server
/// profile so a client can fetch, verify, and cache the catalog without ever assuming a
/// host or guessing a path — `contracts/README.md`, "Locale catalog discovery":
///
/// - **Absence is not legacy.** A server that publishes neither this object nor
///   `i18n.locale-catalog.v1` is a deployment with no catalog. Story keys stay
///   unresolvable; this client must never probe a guessed catalog path.
/// - **`manifestUrl` is the only authority.** There is deliberately no separate origin or
///   base-path field that could disagree with it, so this client never rewrites it onto
///   another host.
/// - **Trust is pinned, not assumed.** ``manifestSha256`` is the digest of the exact
///   manifest bytes; a manifest that does not hash to it is discarded rather than used.
struct LocaleCatalogAdvertisement: Sendable, Equatable, Hashable {
    /// The validated manifest location, in exactly one of the two forms the server publishes.
    let manifestURL: LocaleCatalogManifestURL
    /// The catalog manifest's own `catalogRevision`, canonically spelled `1.<32 hex>`.
    let catalogRevision: String
    /// The catalog manifest's `schemaVersion`. Always `1.0.0` for a catalog this client
    /// implements; any other value means the catalog is unavailable, never guessed at.
    let schemaVersion: String
    /// The catalog's default locale; always a member of ``supportedLocales``.
    let defaultLocale: String
    /// The catalog's published locales, in canonical BCP-47 spelling and ascending order.
    let supportedLocales: [String]
    /// SHA-256 of the manifest bytes served at ``manifestURL``.
    let manifestSha256: String
}

/// The two — and only two — shapes `manifestUrl` may take.
///
/// Modelled as a closed enum rather than a bare `String` so the resolution rule is decided
/// once, at parse time, from the value's own grammar: a hosted deployment publishes a
/// same-origin absolute path resolved against the capabilities response's own origin, and a
/// split/static deployment configures an absolute `https` URL explicitly. There is no third
/// case in which this client would have to choose a host.
enum LocaleCatalogManifestURL: Sendable, Equatable, Hashable {
    /// A root-relative absolute path (the hosted form, `/locale-catalog/manifest.json`),
    /// resolved against the active profile's own origin *and* path prefix.
    case sameOriginPath(String)
    /// An explicitly configured absolute `https` URL for a split/static deployment.
    case absolute(URL)
}

// MARK: - Parsing

extension LocaleCatalogAdvertisement {
    /// Decodes and fully validates the advertisement from an already-parsed capabilities
    /// object.
    ///
    /// Returns `nil` — never a partially-trusted value — for any deviation from the governed
    /// schema: an unknown member (the object is `additionalProperties: false`), a missing
    /// required field, a non-ASCII or non-canonical grammar, a `defaultLocale` outside
    /// `supportedLocales`, an unsorted or duplicated locale list, or a `schemaVersion` this
    /// client does not implement.
    ///
    /// Fail-closed by construction: the caller treats `nil` exactly as it treats absence,
    /// which keeps story keys unresolvable rather than letting a malformed pointer produce a
    /// half-trusted catalog fetch.
    static func decode(from value: JSONValue) -> LocaleCatalogAdvertisement? {
        guard case let .object(object) = value else { return nil }
        let required: Set = [
            "manifestUrl", "catalogRevision", "schemaVersion",
            "defaultLocale", "supportedLocales", "manifestSha256",
        ]
        guard Set(object.keys) == required else { return nil }
        guard case let .string(rawManifestURL)? = object["manifestUrl"],
              let manifestURL = LocaleCatalogManifestURL.parse(rawManifestURL),
              case let .string(catalogRevision)? = object["catalogRevision"],
              LocaleCatalogGrammar.isCatalogRevision(catalogRevision),
              case let .string(schemaVersion)? = object["schemaVersion"],
              schemaVersion == LocaleCatalogLimits.schemaVersion,
              case let .string(defaultLocale)? = object["defaultLocale"],
              LocaleCatalogGrammar.isCanonicalLocaleTag(defaultLocale),
              case let .string(manifestSha256)? = object["manifestSha256"],
              LocaleCatalogGrammar.isSHA256Hex(manifestSha256),
              let supportedLocales = decodeSupportedLocales(object["supportedLocales"]),
              supportedLocales.contains(defaultLocale)
        else { return nil }
        return LocaleCatalogAdvertisement(
            manifestURL: manifestURL,
            catalogRevision: catalogRevision,
            schemaVersion: schemaVersion,
            defaultLocale: defaultLocale,
            supportedLocales: supportedLocales,
            manifestSha256: manifestSha256
        )
    }

    /// `supportedLocales`: 1–64 canonical tags, unique, and in ascending order.
    ///
    /// Order is part of the contract ("in canonical BCP-47 spelling and ascending order, so
    /// the response does not depend on configuration order"), so an out-of-order list is a
    /// server this client does not recognise rather than something to sort locally.
    private static func decodeSupportedLocales(_ value: JSONValue?) -> [String]? {
        guard case let .array(elements)? = value,
              (1 ... LocaleCatalogLimits.maxLocales).contains(elements.count)
        else { return nil }
        var locales: [String] = []
        locales.reserveCapacity(elements.count)
        for element in elements {
            guard case let .string(locale) = element,
                  LocaleCatalogGrammar.isCanonicalLocaleTag(locale)
            else { return nil }
            if let previous = locales.last, !(previous < locale) {
                return nil
            }
            locales.append(locale)
        }
        return locales
    }
}

extension LocaleCatalogManifestURL {
    /// Parses the exact grammar `capabilities.schema.json` publishes, transcribed by hand
    /// rather than evaluated as a regular expression (see ``LocaleCatalogGrammar``).
    static func parse(_ raw: String) -> LocaleCatalogManifestURL? {
        guard !raw.isEmpty,
              raw.utf8.count <= LocaleCatalogLimits.maxManifestURLLength,
              LocaleCatalogGrammar.isASCII(raw),
              !LocaleCatalogGrammar.hasDotSegment(raw)
        else { return nil }
        if raw.hasPrefix("/") {
            return isJSONPath(raw) ? .sameOriginPath(raw) : nil
        }
        return parseAbsoluteHTTPS(raw)
    }

    /// `^/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*\.json`: an absolute path of unreserved
    /// segments ending in `.json`. A trailing newline, a control character, a query, a
    /// fragment, or a percent-escape all fail here rather than reaching a request.
    private static func isJSONPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".json") else { return false }
        let segments = LocaleCatalogGrammar.splitASCII(path, separator: 0x2F)
        // The leading `/` always produces an empty first component; every intermediate
        // segment must be non-empty, and only the final one may be as short as `.json`.
        guard segments.count >= 2, segments[0].isEmpty else { return false }
        let interior = segments.dropFirst().dropLast()
        guard interior.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let last = segments.last, last.count >= 5 else { return false }
        return segments.dropFirst().allSatisfy(isUnreservedSegment)
    }

    private static func isUnreservedSegment(_ segment: [UInt8]) -> Bool {
        segment.allSatisfy { byte in
            (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
                || (0x30 ... 0x39).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x7E || byte == 0x2D
        }
    }

    /// The `absoluteHttpsUrl` branch: a lowercase `https` scheme, a lowercase host that
    /// means one thing to every client, an optional canonical port with the redundant `:443`
    /// already normalized away, and an absolute `.json` path.
    ///
    /// The host rule is WHATWG's "ends in a number": the final label may be neither
    /// all-digits nor an `0x` hex literal, because `127.1`, `2130706433`, `0x7f000001`, and
    /// `01.02.03.04` are all `127.0.0.1` to a browser and something else to a stricter
    /// parser. A dotted-decimal IPv4 host is accepted only in its canonical four-octet
    /// spelling.
    private static func parseAbsoluteHTTPS(_ raw: String) -> LocaleCatalogManifestURL? {
        let scheme = "https://"
        guard raw.hasPrefix(scheme) else { return nil }
        let remainder = raw.dropFirst(scheme.count)
        guard let authorityEnd = remainder.firstIndex(where: { $0 == ":" || $0 == "/" }) else {
            return nil
        }
        let host = String(remainder[remainder.startIndex ..< authorityEnd])
        guard (1 ... 253).contains(host.utf8.count), isPublishableHost(host) else { return nil }

        var pathStart = authorityEnd
        if remainder[authorityEnd] == ":" {
            let afterColon = remainder.index(after: authorityEnd)
            guard let portEnd = remainder[afterColon...].firstIndex(of: "/") else { return nil }
            let portText = String(remainder[afterColon ..< portEnd])
            guard let port = LocaleCatalogGrammar.canonicalInteger(
                Array(portText.utf8), upperBound: 65535
            ), port >= 1, port != 443 else { return nil }
            pathStart = portEnd
        }
        let path = String(remainder[pathStart...])
        guard isJSONPath(path), let url = URL(string: raw) else { return nil }
        return .absolute(url)
    }

    private static func isPublishableHost(_ host: String) -> Bool {
        let labels = LocaleCatalogGrammar.splitASCII(host, separator: 0x2E)
        if isCanonicalIPv4(labels) {
            return true
        }
        guard labels.allSatisfy(isRegisteredNameLabel), let last = labels.last else {
            return false
        }
        return !endsInANumber(last)
    }

    /// Four octets `0-255` with no leading zeros, exactly as the published pattern spells it.
    private static func isCanonicalIPv4(_ labels: [[UInt8]]) -> Bool {
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            LocaleCatalogGrammar.canonicalInteger(label, upperBound: 255) != nil
        }
    }

    /// `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`: 1–63 bytes, lowercase alphanumeric at both
    /// ends, hyphens permitted only inside.
    private static func isRegisteredNameLabel(_ label: [UInt8]) -> Bool {
        guard (1 ... 63).contains(label.count) else { return false }
        let isLowerAlphanumeric: (UInt8) -> Bool = { byte in
            (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte)
        }
        guard isLowerAlphanumeric(label[0]), isLowerAlphanumeric(label[label.count - 1]) else {
            return false
        }
        return label.allSatisfy { isLowerAlphanumeric($0) || $0 == 0x2D }
    }

    /// WHATWG's "ends in a number" rejection: an all-digit final label, or one spelled as an
    /// `0x` hexadecimal literal.
    private static func endsInANumber(_ label: [UInt8]) -> Bool {
        if label.allSatisfy({ (0x30 ... 0x39).contains($0) }) {
            return true
        }
        guard label.count >= 2, label[0] == 0x30, label[1] == 0x78 else { return false }
        return label.dropFirst(2).allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}

// MARK: - Resolution against the active profile

extension LocaleCatalogAdvertisement {
    /// The exact URL this client will request the manifest from, resolved against the
    /// hosting context that actually served the capabilities response.
    ///
    /// A same-origin path is resolved against the exact scheme, host, and port that identify
    /// the active profile's origin. It intentionally replaces any profile path prefix: this
    /// is a root-relative path, not an API-relative one. An absolute URL is used verbatim;
    /// this client never rewrites either form onto another host.
    func resolvedManifestURL(for profile: ServerProfile) -> URL? {
        switch manifestURL {
        case let .absolute(url):
            return url
        case let .sameOriginPath(path):
            guard var components = URLComponents(
                url: profile.baseURL, resolvingAgainstBaseURL: false
            ) else { return nil }
            components.path = path
            components.query = nil
            components.fragment = nil
            return components.url
        }
    }

    /// The origin every request for this catalog must stay on, used to refuse a redirect
    /// that leaves the named host even where the transport would otherwise follow it.
    func namedOrigin(for profile: ServerProfile) -> LocaleCatalogOrigin? {
        guard let url = resolvedManifestURL(for: profile) else { return nil }
        return LocaleCatalogOrigin(url: url)
    }

    /// The absolute URL of one content-addressed chunk, always derived from the *verified*
    /// manifest's fixed root-relative content-addressed path and resolved against the same
    /// origin the manifest was fetched from — never from a path a chunk descriptor could
    /// otherwise choose freely.
    func resolvedChunkURL(path: String, for profile: ServerProfile) -> URL? {
        guard let manifestURL = resolvedManifestURL(for: profile),
              var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// The scheme/host/port triple a catalog fetch is pinned to for the whole of one load.
struct LocaleCatalogOrigin: Sendable, Equatable, Hashable {
    let scheme: String
    let host: String
    let port: Int?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = url.port
    }

    /// Whether `url` is on exactly this origin. Compared component-by-component rather than
    /// by string prefix, so `https://example.com.evil.test` can never match `example.com`.
    func contains(_ url: URL) -> Bool {
        guard let other = LocaleCatalogOrigin(url: url) else { return false }
        return other == self
    }
}
