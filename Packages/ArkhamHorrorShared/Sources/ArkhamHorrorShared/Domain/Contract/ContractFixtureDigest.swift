/// One SHA-256 digest binding a vendored contract artifact to ``ContractPin/current``.
struct VendoredFixtureDigest: Sendable {
    /// The artifact's file name, without extension, as bundled under
    /// `Tests/ArkhamHorrorSharedTests/Fixtures/Contract/`.
    let fileName: String
    /// The lowercase hex-encoded SHA-256 digest of the artifact's exact vendored bytes.
    let sha256Hex: String
}

/// SHA-256 digests of the contract artifacts vendored from
/// `ContractPin.current.backendCommit`, under
/// `Tests/ArkhamHorrorSharedTests/Fixtures/Contract`.
///
/// A drift test recomputes each digest from the bundled artifact's bytes and compares it
/// here. Changing a vendored artifact's bytes, or bumping the pin without re-vendoring and
/// updating this table, fails that test.
enum ContractFixtureDigests {
    static let all: [VendoredFixtureDigest] = [
        VendoredFixtureDigest(
            fileName: "manifest",
            sha256Hex: "b94bbfaeccc28fb42dfb6b9d06abff95a52aeb66fd544040fbdca63c6bddc9f3"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities",
            sha256Hex: "7c27701c91616e6e76c93f76cdeb2a8dca78741bd68e666e869456115cd68208"
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
        VendoredFixtureDigest(
            fileName: "get-game",
            sha256Hex: "f406071dca455c1d87a2192729dda30c08d037bedfc78b3bb3ffc998f7304b93"
        ),
        VendoredFixtureDigest(
            fileName: "game-update",
            sha256Hex: "ceb21a35691320516d3fe68b50d8115f092c4f32dd8f98d6240baeeeb73d07df"
        ),
        VendoredFixtureDigest(
            fileName: "mode-turn-zero",
            sha256Hex: "acc0cb8613b61d0bbb65ecdaefbae433276996fe8412b76046c4c90b3c933b71"
        ),
        VendoredFixtureDigest(
            fileName: "mode-campaign-only",
            sha256Hex: "b68d6e0422852684fd4ebdf2d6097bc6b65edda012cc91ccf38b55ca32b9213f"
        ),
        VendoredFixtureDigest(
            fileName: "mode-campaign-scenario",
            sha256Hex: "36a77bcf41059ca4a5d2c0e5bbd4d9ff3b429da2f6ddbc35d7fb1e1491e88c89"
        ),
        VendoredFixtureDigest(
            fileName: "location-enemy-view",
            sha256Hex: "fd2cc29b6ea081cfa340b02c93194433542ee27ea50c9e841c94d6ed37f419b4"
        ),
        VendoredFixtureDigest(
            fileName: "movement",
            sha256Hex: "c284c0b4244024a072ee7a486c5907db4981c6ff4fed1d55cbe33046fb0b63dc"
        ),
        VendoredFixtureDigest(
            fileName: "act-no-advance-cost",
            sha256Hex: "ef6aa891184deafe2166b58b0df9c0818237a50efa93e3aa69db4aea0dc30a01"
        ),
        VendoredFixtureDigest(
            fileName: "investigator-unhealed-horror-negative",
            sha256Hex: "f251bd1a525fa0eb9508db084fbe7fb86928ec1ecb4472cf0c79cbaf9478762f"
        ),
        VendoredFixtureDigest(
            fileName: "uuid-entity-map",
            sha256Hex: "09ebbcb0bffbcfac4060c878976570b965f10b70a2597111b162662b56b7763d"
        ),
        VendoredFixtureDigest(
            fileName: "card-code-entity-map",
            sha256Hex: "970749b0970f629722515394068afb660b9168a8fbeea768afbbc1cf1ef66492"
        ),
        VendoredFixtureDigest(
            fileName: "question-choose-one",
            sha256Hex: "854d6a2891155ff4da9e075224d4cd5a7519e4e4cb2ec659a740c872f8b799fc"
        ),
        VendoredFixtureDigest(
            fileName: "question-player-window-choose-one",
            sha256Hex: "1a10e17e87e2e77b728484443934e3147ea14d5cdee077cf236fc5efb8334eaf"
        ),
        VendoredFixtureDigest(
            fileName: "question-window-choose-one",
            sha256Hex: "96058cb5e2bb8a1d3beb5107b08fb66b8b4be8eb648317d439c5859657e362f6"
        ),
        VendoredFixtureDigest(
            fileName: "answer-question",
            sha256Hex: "b6d6b4d70acadd6d11d7c30fd67d052085384c478a00520d68c5c2f4d1b18fa7"
        ),
    ]
}
