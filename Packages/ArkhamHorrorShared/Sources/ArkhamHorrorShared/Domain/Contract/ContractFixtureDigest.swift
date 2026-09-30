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
            sha256Hex: "6ff8811f01fc9b783eddce4463e089eb0ba2db10ef37074e48777917c7eab679"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities",
            sha256Hex: "0d16cdd20da1e0828341d8a65360e519c7f5879ea39bb3bfc02101cd4fe1acd5"
        ),
        VendoredFixtureDigest(
            fileName: "catalog",
            sha256Hex: "481f42cbac1fcb208cdb1b626a3cc6951c35531383e7439dc3c0d7c02a9044ac"
        ),
        VendoredFixtureDigest(
            fileName: "decks",
            sha256Hex: "be1b19529d95386c6c2ed0b5c665aa25ae64a450c8a3f412d10b8523b966aaff"
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
            sha256Hex: "0e187eaf21df45f9a0a57df2a5961d41492981caee51e3322f8961d6c81c87ac"
        ),
        VendoredFixtureDigest(
            fileName: "game-update",
            sha256Hex: "6d16ee03cb099b63f42b6d38869d9cf18217c5337276a96e1eeee728613b6e1a"
        ),
        VendoredFixtureDigest(
            fileName: "mode-turn-zero",
            sha256Hex: "ac598791652b79370375631658794554cc8af3de97379c11696793bf63ac8a20"
        ),
        VendoredFixtureDigest(
            fileName: "mode-campaign-only",
            sha256Hex: "51162c3cbbd0e479f22f591639e7e8919a84aa3a7316be48f9aace545bf8e81f"
        ),
        VendoredFixtureDigest(
            fileName: "mode-campaign-scenario",
            sha256Hex: "7f4348da15b7fb2fe761753b9cdadc3124307a65a75bfcf9fd8546a7cc5c2897"
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
            sha256Hex: "0e29e060f65b8ec05886a0e1339d0dbb89995987dc006d9cd5f6311a5c491805"
        ),
        VendoredFixtureDigest(
            fileName: "question-window-choose-one",
            sha256Hex: "96058cb5e2bb8a1d3beb5107b08fb66b8b4be8eb648317d439c5859657e362f6"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-act-objective",
            sha256Hex: "e192721b78db903beee104cd4bf25924f458a29a6cf408dbed62f16c003fe40d"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-act-advance",
            sha256Hex: "21eb483b08ca6cc6ad76b3d7884dde7f817cc9da9945e71ab975527c13b7fd6b"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-act-objective",
            sha256Hex: "768c77f900c61f6bd0e99514b6b71c38a6c939ce192e9f6d0d43d4ef8c623fc6"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-act-advance",
            sha256Hex: "232062dc5467843242763a428beaa212e082752a6ae02c1f753165f76e322841"
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
            sha256Hex: "6ae49986f27c9ab934ddd53b08e2dd6c3fa33a85a2ee258409c0321332ed731b"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-commit",
            sha256Hex: "0cef8bb88be1ac2feb7cd2d37b952bf54fa47b4ea7d83474326baf9da7fb9b18"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-reveal-window",
            sha256Hex: "6ae49986f27c9ab934ddd53b08e2dd6c3fa33a85a2ee258409c0321332ed731b"
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
            fileName: "question-presentation-encounter-deck-draw",
            sha256Hex: "a8343bef781598fe6e81098d93e9d0b279f851d4bbf2a6a23ce6852d0f4d1217"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack",
            sha256Hex: "888ab4cf258272dc7ea5ad70cd34dfcff167f409cee2c4a5b0a31d4f906db797"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack",
            sha256Hex: "d99928af1d38ffe97adbeea9861e8f5edc43b937a309e90e27f5fb6071b555b4"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack-damage-assignment",
            sha256Hex: "36d20df58661bb583dfbe5350519d164d751f5ddc85924a0f8e2917ce1bbbdff"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack-assign-damage",
            sha256Hex: "5111ec20fa5af6e53f7558715529085f2a17e8f2941510ea0ca6c9439cd6ebc7"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack-assign-horror",
            sha256Hex: "0799759424dbcec2420a41c8e800e0d41a5eee5bc2e4f032027837503fcc85d6"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack-remaining-damage-assignment",
            sha256Hex: "99e09d65b292ed3535e1d908a76e90855db7b256adfda55755c41fccf4c96018"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack-remaining-horror-assignment",
            sha256Hex: "5e3eb6076ebeb406632b4aab3a5d0d9b02275c531afb2db52dffb369182df4c7"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack-assign-remaining-damage",
            sha256Hex: "e7c4bcbd8f246c8c34c3c1ef42e11bd342ca18fe88d8193c46b4647fd424a767"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack-assign-remaining-horror",
            sha256Hex: "e7c4bcbd8f246c8c34c3c1ef42e11bd342ca18fe88d8193c46b4647fd424a767"
        ),
        VendoredFixtureDigest(
            fileName: "question-player-window-enemy-actions",
            sha256Hex: "8071d15dd7c4151757885d04cf6ac3b3b452ac6bd79590f4031b3993993a5187"
        ),
        VendoredFixtureDigest(
            fileName: "question-player-window-engage-action",
            sha256Hex: "fcda1583d42da4fca7c9f2be593bd0c878dca588fe15d32f24c512154fa8212b"
        ),
        VendoredFixtureDigest(
            fileName: "question-roland-defeat-reaction",
            sha256Hex: "13471177b2ec181fe80b846b8812b5e079bfc22eb763219edc99c05f860ae093"
        ),
        VendoredFixtureDigest(
            fileName: "question-cover-up-reaction",
            sha256Hex: "970721a646443a5eb5770d3103ee266b579506b6c76b7f487d287c4f9dae7089"
        ),
        VendoredFixtureDigest(
            fileName: "question-round-end-forced-ability",
            sha256Hex: "ccf51b1cd6d4f35a23d05c69d6009d47c8ca60f531d69c7c429a26beac412f5f"
        ),
        VendoredFixtureDigest(
            fileName: "question-treachery-forced-ability",
            sha256Hex: "e06cd3debf7b77313c4d4fcf8732944915022e2f99df4535a4177c1521cf899f"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-treachery-forced-ability",
            sha256Hex: "bd988ba0d52a24a7b7ef6591a49a769bec440e90eca6915bbb250978f99b3b06"
        ),
        VendoredFixtureDigest(
            fileName: "question-agenda-advance",
            sha256Hex: "c92f0ab199c1e0797359360322d479a1dbab9271a229ab6c17009977320a1eaf"
        ),
        VendoredFixtureDigest(
            fileName: "question-agenda-consequence",
            sha256Hex: "8cf704ab50b76b7800ff1685e6d70c488f863b48370d1ba8d16827d1527dd16e"
        ),
        VendoredFixtureDigest(
            fileName: "question-agenda-horror-assignment",
            sha256Hex: "7bb195142065b5ccd0fa9b32a3833f472e4e2f08e4b1596e0b211625c1dffc31"
        ),
        VendoredFixtureDigest(
            fileName: "replay-attestation",
            sha256Hex: "801e9961121bd185e31cdf8fc3681cc5b62a31b76a8c1da7d5d70df6105819e2"
        ),
        VendoredFixtureDigest(
            fileName: "replay-attestation.schema",
            sha256Hex: "ce0a95eb11996ed95ddc47e92a2071202e6ff01d8ff9cf0d352dd13e24739194"
        ),
        VendoredFixtureDigest(
            fileName: "basic-choice-question.schema",
            sha256Hex: "b545376fafbd9dcc4aa47ad625d91bc96ddd2876ea5be6cbb7a5fc1ca0aa3649"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation.schema",
            sha256Hex: "63da9456efa6059ed4d754488998bcb203186887c1945abd27a5d9a2130ef5b7"
        ),
    ] + movementEntry
}

extension ContractFixtureDigests {
    private static let movementEntry: [VendoredFixtureDigest] = [
        VendoredFixtureDigest(
            fileName: "question-gathering-movement",
            sha256Hex: "bfef8a3ead15a37cd119da96e9173f9d8c01e17b9b29abb0d4dd920fd277221f"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-cellar-entry-forced",
            sha256Hex: "ea7c802ed3064fda9707c595ac98a3d96f8b6d4c923ae5ff4657f1e7379beba4"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-attic-entry-forced",
            sha256Hex: "f0859c41b10dbe80f6236d7cfa1152116239c8fb04b0f8816a570a60122f3d7e"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-cellar-damage-assignment",
            sha256Hex: "1d746cbaa060ef427516d1b949c2e40600c19a86762a0eb892db1f3ade916473"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-attic-horror-assignment",
            sha256Hex: "9241df0b7a57a5be5d0d2c35b47635ba39823a6179b018ce730a8e124bb3f6b3"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-movement",
            sha256Hex: "e87a92d62a40cbff46a55f8476984c84b130428f8b077d86131ac013cf394a00"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-cellar-entry-forced",
            sha256Hex: "a9eab9713c85b3b3556a88611c4513ec98d0a77a0bf7f233b3f6c1a8a673c850"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-attic-entry-forced",
            sha256Hex: "36117fa21a39361bbc06d54bdd76905855d3ab4913f0fd5973611ca74316f0cc"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-cellar-damage-assignment",
            sha256Hex: "b55f3887017f1eb392f7b15faf6324d81471712c0f18294c175ec9ea751cfd8f"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-attic-horror-assignment",
            sha256Hex: "5b00bb0d74400bf6e1b03a64332d500cb70d368bc68fe4cd1e1bbe8e65b308d7"
        ),
    ]
}
