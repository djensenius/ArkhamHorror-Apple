@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetSourceNamespace")
struct AssetSourceNamespaceTests {
    // MARK: - Raw-authority loopback matrix (the authoritative http entry point)

    @Test(
        "http is accepted only for the exact loopback authorities, via the raw entry point",
        arguments: ["localhost", "127.0.0.1", "::1"]
    )
    func loopbackHTTPAccepted(host: String) throws {
        let hostForURL = host == "::1" ? "[::1]" : host
        let namespace = try AssetSourceNamespace(rawAssetBase: "http://\(hostForURL):8080/assets")
        #expect(namespace.canonicalOrigin.port == 8080)
    }

    @Test(
        "http is rejected for every non-loopback host, including near-miss loopback spellings",
        arguments: [
            "example.com", "128.0.0.1", "127.0.0.1.evil.com", "localhost.evil.com",
            "0.0.0.0", "[::]", "sub.localhost", "LOCALHOST.",
        ]
    )
    func httpRejectedForNonLoopback(host: String) {
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(rawAssetBase: "http://\(host)/assets")
        }
    }

    @Test(
        "http is accepted for any strict dotted-quad address in the whole 127.0.0.0/8 range",
        arguments: ["127.0.0.1", "127.1.1.1", "127.255.255.255", "127.0.0.2"]
    )
    func loopbackHTTPAcceptedForWholeIPv4Range(host: String) throws {
        let namespace = try AssetSourceNamespace(rawAssetBase: "http://\(host)")
        #expect(namespace.canonicalOrigin.host == host)
    }

    @Test(
        """
        Smuggled/lookalike loopback authorities are rejected against the raw literal \
        text, before Foundation's own percent-decoding or normalization can turn \
        them into something that only resolves to an accepted loopback form
        """,
        arguments: [
            // Percent-escaped `localhost` and `127.0.0.1`: must not decode-then-match.
            "http://local%68ost",
            "http://127%2e0%2e0%2e1",
            // Full-width (non-ASCII) dots: must not IDNA/Unicode-normalize to dots.
            "http://127。0。0。1",
            // Circled-letter Unicode lookalike of `localhost`.
            "http://ⓁⓞⓒⓐⓁⓗⓞⓢⓣ",
            // A raw userinfo component ahead of a loopback host is still rejected.
            "http://user@localhost",
            "http://user:pass@127.0.0.1",
            // A trailing dot must not be treated as the same host as `localhost`.
            "http://localhost.",
            // Non-ASCII bytes anywhere in the authority are rejected outright.
            "http://löcalhost",
            // An unbracketed multi-colon authority can never be a strict loopback
            // match; only the bracketed `[::1]` literal is accepted.
            "http://::1",
            // A non-numeric or out-of-range raw port must not reach URL construction.
            "http://localhost:abc",
            "http://localhost:0",
            "http://localhost:99999",
            "http://[::1]:notaport",
            // Ambiguous numeric IPv4 forms some parsers treat as loopback must not
            // be accepted by this validator's strict dotted-quad check.
            "http://127.1",
            "http://0x7f000001",
            "http://017700000001",
            "http://2130706433",
            "http://127.0.010.1",
        ]
    )
    func rawAuthoritySmugglingRejected(rawURL: String) {
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(rawAssetBase: rawURL)
        }
    }

    @Test("https is accepted for an arbitrary host, via either entry point")
    func httpsAcceptedForArbitraryHost() throws {
        let url = try #require(URL(string: "https://assets.arkhamhorror.app/cdn"))
        let fromURL = try AssetSourceNamespace(assetBase: url)
        let fromRaw = try AssetSourceNamespace(rawAssetBase: "https://assets.arkhamhorror.app/cdn")
        for namespace in [fromURL, fromRaw] {
            #expect(
                namespace.canonicalOrigin.absoluteString
                    == "https://assets.arkhamhorror.app:443"
            )
            #expect(namespace.basePath == "/cdn")
        }
    }

    // MARK: - URL-only construction can never authorize cleartext

    @Test(
        """
        Constructing from an already-parsed URL never authorizes http, even for a \
        literal loopback authority: by the time a URL exists, Foundation's own \
        parsing has already folded any smuggled authority into normalized text \
        indistinguishable from a genuine one, so this entry point must reject \
        unconditionally rather than re-inspect the (already-untrustworthy) URL
        """,
        arguments: ["localhost", "127.0.0.1", "[::1]", "example.com"]
    )
    func urlOnlyConstructionNeverAuthorizesHTTP(host: String) throws {
        let url = try #require(URL(string: "http://\(host):8080/assets"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("Constructing from an already-parsed URL rejects any non-https scheme")
    func urlOnlyConstructionRejectsNonHTTPSScheme() throws {
        let url = try #require(URL(string: "ftp://assets.example.com"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    // MARK: - Canonicalization

    @Test("Scheme and host are lowercased; an implicit port becomes explicit")
    func canonicalizesLowercaseAndExplicitPort() throws {
        let url = try #require(URL(string: "HTTPS://Assets.ArkhamHorror.App"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.canonicalOrigin.absoluteString == "https://assets.arkhamhorror.app:443")
    }

    @Test("A trailing slash on the base path is normalized away")
    func trailingSlashNormalized() throws {
        let url = try #require(URL(string: "https://assets.example.com/cdn/"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.basePath == "/cdn")
    }

    @Test("A bare root path normalizes to the empty string, not '/'")
    func rootPathNormalizesToEmpty() throws {
        let url = try #require(URL(string: "https://assets.example.com/"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.basePath.isEmpty)
    }

    @Test("Base path case is preserved, not lowercased")
    func basePathCasePreserved() throws {
        let url = try #require(URL(string: "https://assets.example.com/CDN/Mixed-Case"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.basePath == "/CDN/Mixed-Case")
    }

    @Test("Repeated slashes within the base path are collapsed")
    func repeatedInternalSlashesCollapsed() throws {
        let url = try #require(URL(string: "https://assets.example.com/cdn//assets///more"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.basePath == "/cdn/assets/more")
    }

    @Test("Two base-path spellings sharing one request URL share one canonicalIdentity")
    func repeatedSlashSpellingsShareOneIdentity() throws {
        let doubled = try AssetSourceNamespace(
            assetBase: #require(URL(string: "https://assets.example.com/cdn//assets/"))
        )
        let single = try AssetSourceNamespace(
            assetBase: #require(URL(string: "https://assets.example.com/cdn/assets"))
        )
        #expect(doubled.canonicalIdentity == single.canonicalIdentity)

        // Prove this actually matches how `AssetCandidate.url(base:)` builds
        // the request URL (it splits `basePath` on `/`, which already
        // collapses repeated slashes) — not just that the two namespaces
        // happen to agree with each other.
        let candidate = AssetCandidateFactory.make(
            segments: ["01001.avif"], localeRoot: nil, format: .avif
        )
        #expect(candidate.url(base: doubled) == candidate.url(base: single))
    }

    @Test("An all-slash base path normalizes to the empty string")
    func allSlashPathNormalizesToEmpty() throws {
        let url = try #require(URL(string: "https://assets.example.com//"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.basePath.isEmpty)
    }

    @Test("An explicit non-default port is preserved")
    func explicitPortPreserved() throws {
        let url = try #require(URL(string: "https://assets.example.com:9443/cdn"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.canonicalOrigin.port == 9443)
    }

    @Test("An explicit default port (443 for https) is folded away, not preserved verbatim")
    func explicitDefaultPortFolded() throws {
        let namespace = try AssetSourceNamespace(
            rawAssetBase: "https://assets.example.com:443/cdn"
        )
        #expect(namespace.canonicalOrigin.absoluteString == "https://assets.example.com:443")
        let implicit = try AssetSourceNamespace(rawAssetBase: "https://assets.example.com/cdn")
        #expect(namespace.canonicalIdentity == implicit.canonicalIdentity)
    }

    // MARK: - Hostile input rejection

    @Test("Embedded credentials are rejected")
    func credentialsRejected() throws {
        let url = try #require(URL(string: "https://user:pass@assets.example.com"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("A query string is rejected")
    func queryRejected() throws {
        let url = try #require(URL(string: "https://assets.example.com/cdn?x=1"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("A fragment is rejected")
    func fragmentRejected() throws {
        let url = try #require(URL(string: "https://assets.example.com/cdn#frag"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("An unsupported scheme is rejected")
    func unsupportedSchemeRejected() throws {
        let url = try #require(URL(string: "ftp://assets.example.com"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("An empty host is rejected")
    func emptyHostRejected() throws {
        let url = try #require(URL(string: "https:///cdn"))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("Query/fragment injection through the raw entry point is rejected")
    func rawQueryFragmentInjectionRejected() {
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(rawAssetBase: "https://assets.example.com/cdn?x=1")
        }
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(rawAssetBase: "https://assets.example.com/cdn#frag")
        }
    }

    @Test("Empty raw input is rejected")
    func emptyRawInputRejected() {
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(rawAssetBase: "")
        }
    }

    // MARK: - Cache namespace isolation

    @Test("Two distinct hosts never share a canonical identity")
    func distinctHostsNeverCollide() throws {
        let first =
            try AssetSourceNamespace(assetBase: #require(URL(string: "https://one.example.com")))
        let second =
            try AssetSourceNamespace(assetBase: #require(URL(string: "https://two.example.com")))
        #expect(first.canonicalIdentity != second.canonicalIdentity)
    }

    @Test("A hosted and a self-hosted loopback deployment never share a canonical identity")
    func hostedAndSelfHostedNeverCollide() throws {
        let hosted = AssetSourceNamespace.hosted
        let selfHosted = try AssetSourceNamespace(rawAssetBase: "http://localhost:8080")
        #expect(hosted.canonicalIdentity != selfHosted.canonicalIdentity)
    }

    @Test("Two loopback deployments differing only in base path never share a canonical identity")
    func differingBasePathsNeverCollide() throws {
        let first = try AssetSourceNamespace(rawAssetBase: "http://localhost:8080/a")
        let second = try AssetSourceNamespace(rawAssetBase: "http://localhost:8080/b")
        #expect(first.canonicalIdentity != second.canonicalIdentity)
    }

    @Test("Two loopback deployments differing only in port never share a canonical identity")
    func differingPortsNeverCollide() throws {
        let first = try AssetSourceNamespace(rawAssetBase: "http://localhost:8080")
        let second = try AssetSourceNamespace(rawAssetBase: "http://localhost:8081")
        #expect(first.canonicalIdentity != second.canonicalIdentity)
    }
}
