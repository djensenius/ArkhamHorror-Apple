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
            sha256Hex: "9aab847c46453a08f8ca03896809002548759142f2afe3db83f0811ff97a67db"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities",
            sha256Hex: "764869f1d8f0d1f05e00644ca4dadccb8cbd83fb3bc47c65c45364f233645a3d"
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
        VendoredFixtureDigest(
            fileName: "question-read",
            sha256Hex: "e7397b59c9a714a003a0edac3f584b284c5cab03e75b59c1e9b4a84d86964006"
        ),
        VendoredFixtureDigest(
            fileName: "question-read-scenario-intro",
            sha256Hex: "98cac0992deff7f08005fc25a0227ef62b9aedde00c3b6dcceb25e503d671fd3"
        ),
        VendoredFixtureDigest(
            fileName: "question-read-with-cards",
            sha256Hex: "402805337459a8e82a518d515f2bafdb4d4d6e6474ae190002dd885a5ed50ba1"
        ),
        VendoredFixtureDigest(
            fileName: "question-choose-one-location",
            sha256Hex: "5ce62cbaee22e32f4b8d84e563d331b58d087c3d5f6b3061c7cbfdb177af0f79"
        ),
        VendoredFixtureDigest(
            fileName: "question-choose-one-location-multiple",
            sha256Hex: "25751cccc02dc18de38e0cbebf71acb5303d47df3705367f0c14089853bcbe07"
        ),
        VendoredFixtureDigest(
            fileName: "question-mulligan",
            sha256Hex: "88249e7206671dbb5f43a8187c9fa6e0cbbee1859e06957ca1a454455d156029"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-fast-window",
            sha256Hex: "faa049601d544817746c3621e6865a119c5a38c5eba8daf477da2728a250a913"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-commit",
            sha256Hex: "0cef8bb88be1ac2feb7cd2d37b952bf54fa47b4ea7d83474326baf9da7fb9b18"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-reveal-window",
            sha256Hex: "faa049601d544817746c3621e6865a119c5a38c5eba8daf477da2728a250a913"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-apply-results",
            sha256Hex: "ca3834a719c64a263c31982cfb5987c08da40ec3494d2380ccffaebb46e11774"
        ),
        VendoredFixtureDigest(
            fileName: "question-encounter-deck-draw",
            sha256Hex: "fb341f57cba32fd0d01e3d67098fa7684cd51b6b2b008c65fea61db5487ac703"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack",
            sha256Hex: "1f5ce9f0742e0f3e6891c9e464c19a863038d75cb95ebf7b4ea0ddbbc9fd6b1d"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack",
            sha256Hex: "d99928af1d38ffe97adbeea9861e8f5edc43b937a309e90e27f5fb6071b555b4"
        ),
        VendoredFixtureDigest(
            fileName: "basic-choice-question.schema",
            sha256Hex: "2aa91bdd3de9a20a503b80cc6c12bca2206a23ec0358b99b42e366736ab16107"
        ),
    ]
}
