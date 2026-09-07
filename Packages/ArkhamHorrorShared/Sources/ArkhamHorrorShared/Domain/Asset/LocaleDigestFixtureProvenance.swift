/// One SHA-256 digest binding a vendored *raw* upstream localized-digest artifact (before
/// this package's own compaction transform) to its exact pinned upstream commit and path.
///
/// Mirrors ``VendoredFixtureDigest``/``ContractFixtureDigests``'s existing pattern for the
/// backend contract fixtures: an immutable, source-controlled manifest of exactly which
/// upstream bytes are vendored, separate from (and checked independently of) the
/// deterministic compaction transform `LocalizedDigestCompactorDriftTests` already exercises
/// against these same bytes.
struct VendoredLocaleDigestFixture: Sendable {
    /// The artifact's file name, without extension, as bundled under
    /// `Tests/ArkhamHorrorSharedTests/Fixtures/LocaleDigests/raw/`.
    let fileName: String
    /// The upstream repository path this file was vendored from, at
    /// ``LocaleDigestProvenance/upstreamCommit``.
    let upstreamPath: String
    /// The lowercase hex-encoded SHA-256 digest of the artifact's exact vendored bytes.
    let sha256Hex: String
}

/// Identifies the exact upstream source every raw locale digest fixture is vendored from.
enum LocaleDigestProvenance {
    /// The upstream web-client repository these raw digests are vendored from.
    static let upstreamRepositoryURL = "https://github.com/djensenius/ArkhamHorror.git"
    /// The exact, immutable commit every raw fixture below was vendored from. Never a
    /// branch or tag: a 40-character commit SHA, so the pin cannot silently drift to a
    /// later revision of the same ref.
    static let upstreamCommit = "6a1befbd7b01b4a0f763e41260ae4dd1a5d14c27"
}

/// SHA-256 digests of the *raw* (pre-compaction) localized-digest artifacts vendored from
/// `LocaleDigestProvenance.upstreamCommit`, under
/// `Tests/ArkhamHorrorSharedTests/Fixtures/LocaleDigests/raw`.
///
/// A drift test recomputes each digest from the bundled artifact's bytes and compares it
/// here, so an edited/substituted raw fixture (whether or not its *decoded* JSON content
/// still happens to compact identically) is caught independently of
/// `LocalizedDigestCompactorDriftTests`'s own content-level comparison.
enum LocaleDigestFixtureDigests {
    static let all: [VendoredLocaleDigestFixture] = [
        VendoredLocaleDigestFixture(
            fileName: "it",
            upstreamPath: "frontend/src/digests/ita.json",
            sha256Hex: "e56e8b7efd4f0923a2c0b01f7ef0f9b27c4abfe7bf5c963616e1dc0932a9b959"
        ),
        VendoredLocaleDigestFixture(
            fileName: "fr",
            upstreamPath: "frontend/src/digests/fr.json",
            sha256Hex: "39feec586970f6a004819bdcf6d20942f53a151efc2a7ed928e501f780faed55"
        ),
        VendoredLocaleDigestFixture(
            fileName: "es",
            upstreamPath: "frontend/src/digests/es.json",
            sha256Hex: "df3ce88328fd603f9ae4136214fa52fd4fd5448c778f36836bbec64affc9b236"
        ),
        VendoredLocaleDigestFixture(
            fileName: "ko",
            upstreamPath: "frontend/src/digests/ko.json",
            sha256Hex: "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
        ),
        VendoredLocaleDigestFixture(
            fileName: "zh",
            upstreamPath: "frontend/src/digests/zh.json",
            sha256Hex: "ed8e006012040f1ea3358977959534438b16d84f0659c3d6226d9c9af39b9353"
        ),
    ]
}
