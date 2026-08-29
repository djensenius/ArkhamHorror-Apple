/// One SHA-256 digest binding a vendored contract artifact to ``ContractPin/current``.
struct VendoredFixtureDigest: Sendable {
    /// The artifact's file name, without extension, as bundled under `Fixtures/`.
    let fileName: String
    /// The lowercase hex-encoded SHA-256 digest of the artifact's exact vendored bytes.
    let sha256Hex: String
}

/// SHA-256 digests of the contract artifacts vendored from
/// `ContractPin.current.backendCommit`, under `Tests/ArkhamHorrorSharedTests/Fixtures`.
///
/// A drift test recomputes each digest from the bundled artifact's bytes and compares it
/// here. Changing a vendored artifact's bytes, or bumping the pin without re-vendoring and
/// updating this table, fails that test.
enum ContractFixtureDigests {
    static let all: [VendoredFixtureDigest] = [
        VendoredFixtureDigest(
            fileName: "manifest",
            sha256Hex: "1c5b41c75766a2e94575f6b88b95d703dc125874280bfdde1611a7a8c100db5e"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities",
            sha256Hex: "eef5172ea810103ccde4b3182a14a3b50bfee727b2b92335804287a596fd3e1d"
        ),
        VendoredFixtureDigest(
            fileName: "catalog",
            sha256Hex: "653e00824e6834b1a21b803ef01b8a1a4abe4987410830f70890f3accb71ad82"
        ),
        VendoredFixtureDigest(
            fileName: "decks",
            sha256Hex: "037153d7c611b2b67e101a6eb847f138e4c2b433a06f567d7d8e05857e21165d"
        ),
        VendoredFixtureDigest(
            fileName: "game-lifecycle",
            sha256Hex: "436fa9aea0e0e256b68b7f6038c15692e66af2677293b41bca25c691ab601204"
        ),
        VendoredFixtureDigest(
            fileName: "game-list",
            sha256Hex: "5e89ffcf2cba73da7df12cd2f0a6fe6ccd951a2f1d7b5b404454abf2055785ff"
        ),
    ]
}
