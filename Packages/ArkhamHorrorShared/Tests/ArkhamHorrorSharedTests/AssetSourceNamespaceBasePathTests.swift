@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Canonicalization/base-path behavior for ``AssetSourceNamespace``, split out
/// from `AssetSourceNamespaceTests` (which covers the raw-authority loopback
/// matrix and hostile-input rejection) purely to stay under SwiftLint's
/// `type_body_length`.
@Suite("AssetSourceNamespace base path canonicalization")
struct AssetSourceNamespaceBasePathTests {
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

    @Test(
        "A dot-segment anywhere in the base path is rejected",
        arguments: [
            "https://assets.example.com/a/../img",
            "https://assets.example.com/a/./img",
            "https://assets.example.com/../img",
            "https://assets.example.com/..",
            "https://assets.example.com/a/..%2f/img",
        ]
    )
    func dotSegmentInBasePathRejected(rawURLString: String) throws {
        let url = try #require(URL(string: rawURLString))
        #expect(throws: AssetError.invalidAssetBase) {
            try AssetSourceNamespace(assetBase: url)
        }
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
}
