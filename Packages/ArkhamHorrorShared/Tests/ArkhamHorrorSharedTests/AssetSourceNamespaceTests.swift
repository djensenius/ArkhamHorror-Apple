@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetSourceNamespace")
struct AssetSourceNamespaceTests {
    // MARK: - Loopback matrix

    @Test(
        "http is accepted only for the exact loopback authorities",
        arguments: ["localhost", "127.0.0.1", "::1"]
    )
    func loopbackHTTPAccepted(host: String) throws {
        let hostForURL = host == "::1" ? "[::1]" : host
        let url = try #require(URL(string: "http://\(hostForURL):8080/assets"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.canonicalOrigin.port == 8080)
    }

    @Test(
        "http is rejected for every non-loopback host, including near-miss loopback spellings",
        arguments: [
            "example.com", "127.0.0.2", "127.0.0.1.evil.com", "localhost.evil.com",
            "0.0.0.0", "[::]", "sub.localhost", "LOCALHOST.",
        ]
    )
    func httpRejectedForNonLoopback(host: String) throws {
        let url = try #require(
            URL(string: "http://\(host)/assets"),
            """
            Test input host '\(host)' must itself produce a valid URL, or this test \
            would vacuously pass without ever asserting rejection
            """
        )
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
    }

    @Test("https is accepted for an arbitrary host")
    func httpsAcceptedForArbitraryHost() throws {
        let url = try #require(URL(string: "https://assets.arkhamhorror.app/cdn"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.canonicalOrigin.absoluteString == "https://assets.arkhamhorror.app:443")
        #expect(namespace.basePath == "/cdn")
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

    @Test("An explicit non-default port is preserved")
    func explicitPortPreserved() throws {
        let url = try #require(URL(string: "https://assets.example.com:9443/cdn"))
        let namespace = try AssetSourceNamespace(assetBase: url)
        #expect(namespace.canonicalOrigin.port == 9443)
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
        let selfHosted =
            try AssetSourceNamespace(assetBase: #require(URL(string: "http://localhost:8080")))
        #expect(hosted.canonicalIdentity != selfHosted.canonicalIdentity)
    }

    @Test("Two loopback deployments differing only in base path never share a canonical identity")
    func differingBasePathsNeverCollide() throws {
        let first =
            try AssetSourceNamespace(assetBase: #require(URL(string: "http://localhost:8080/a")))
        let second =
            try AssetSourceNamespace(assetBase: #require(URL(string: "http://localhost:8080/b")))
        #expect(first.canonicalIdentity != second.canonicalIdentity)
    }
}
