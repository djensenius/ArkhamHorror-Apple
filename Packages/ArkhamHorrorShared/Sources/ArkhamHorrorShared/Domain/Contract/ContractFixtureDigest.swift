/// One SHA-256 digest binding a vendored contract artifact to ``ContractPin/current``.
struct VendoredFixtureDigest: Sendable {
    /// The artifact's file name, without extension, as bundled under
    /// `Tests/ArkhamHorrorSharedTests/Fixtures/Contract/`.
    let fileName: String
    /// The lowercase hex-encoded SHA-256 digest of the artifact's exact vendored bytes.
    let sha256Hex: String
}

// swiftlint:disable file_length type_body_length

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
            fileName: "act-no-advance-cost",
            sha256Hex: "ef6aa891184deafe2166b58b0df9c0818237a50efa93e3aa69db4aea0dc30a01"
        ),
        VendoredFixtureDigest(
            fileName: "answer-amounts",
            sha256Hex: "9e2344dd6b03c2ca40b0ede6f223dc50cac0c20f9af7a5b65d9ddd770e4fd555"
        ),
        VendoredFixtureDigest(
            fileName: "answer-rejected",
            sha256Hex: "ad8069b02586f3cfe4677dc6fa25d2297d9f2f6cbd3366c6954845446a0440dc"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack",
            sha256Hex: "d99928af1d38ffe97adbeea9861e8f5edc43b937a309e90e27f5fb6071b555b4"
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
            fileName: "answer-enemy-attack-assign-remaining-damage",
            sha256Hex: "e7c4bcbd8f246c8c34c3c1ef42e11bd342ca18fe88d8193c46b4647fd424a767"
        ),
        VendoredFixtureDigest(
            fileName: "answer-enemy-attack-assign-remaining-horror",
            sha256Hex: "e7c4bcbd8f246c8c34c3c1ef42e11bd342ca18fe88d8193c46b4647fd424a767"
        ),
        VendoredFixtureDigest(
            fileName: "answer-exchange-amounts",
            sha256Hex: "358e6dbd9a75ddf0080df46954cc58dd0df538205375cab61bd882396bf84f9e"
        ),
        VendoredFixtureDigest(
            fileName: "answer-payment-amounts",
            sha256Hex: "d55055b00a8d4d7c93ca121af1d870367dd110ae95e271b47770b14bcf12bd1e"
        ),
        VendoredFixtureDigest(
            fileName: "answer-question",
            sha256Hex: "b6d6b4d70acadd6d11d7c30fd67d052085384c478a00520d68c5c2f4d1b18fa7"
        ),
        VendoredFixtureDigest(
            fileName: "arkhamdb",
            sha256Hex: "6f65fa4ce1abc81da016b6fa3bad93b2f1e4bbee5ff5bf08f7f09749088ada40"
        ),
        VendoredFixtureDigest(
            fileName: "arkhamdb.schema",
            sha256Hex: "43a8782d8daab78f4db076a282a56567342b7b497683e497e31d7c7eb8a7e898"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities-arkhamdb",
            sha256Hex: "548cec7914c02fe7cb78c37f71d9346f0e8bacfcca428db0d915bf709932ffc4"
        ),
        VendoredFixtureDigest(
            fileName: "basic-choice-question.schema",
            sha256Hex: "2d611ed83a47a8efb7843f989434dd772421528e9945f7e2c5054d4395f10172"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities",
            sha256Hex: "e7e2375383add93478ce22929c811fcd813c24dbbbee0b4dc3630ed53c577e10"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities-locale-catalog",
            sha256Hex: "1b376e4e5edde3b8cf14eb0291622f8826d31183df14d3237db29c7218c9beeb"
        ),
        VendoredFixtureDigest(
            fileName: "capabilities.schema",
            sha256Hex: "a71638283a94b4e68c29c1a705dba0f007a3b5a28de324fecdcfdbd179430658"
        ),
        VendoredFixtureDigest(
            fileName: "campaign-catalog",
            sha256Hex: "1319f85f8d709c2e7134586621da42cb376048154cc5498e3f24a395c365c250"
        ),
        VendoredFixtureDigest(
            fileName: "campaign-catalog.schema",
            sha256Hex: "e49e5000658288b4324280fe4164359b419a0c91fbbf7c16c045385060c23dc1"
        ),
        VendoredFixtureDigest(
            fileName: "card-code-entity-map",
            sha256Hex: "970749b0970f629722515394068afb660b9168a8fbeea768afbbc1cf1ef66492"
        ),
        VendoredFixtureDigest(
            fileName: "catalog",
            sha256Hex: "481f42cbac1fcb208cdb1b626a3cc6951c35531383e7439dc3c0d7c02a9044ac"
        ),
        VendoredFixtureDigest(
            fileName: "client-answer.schema",
            sha256Hex: "76a9a9d2c1190053b9d1876790da465506fc1d798498b622d2611b05d13973a0"
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
            sha256Hex: "eb3d06e26059c20225389e22a945088899c4433480a39602818f4003365a1fbf"
        ),
        VendoredFixtureDigest(
            fileName: "game-update",
            sha256Hex: "be2126433a0d50527145c0ee43cb442ce5bba5427e61899ba9d3b371c2f74985"
        ),
        VendoredFixtureDigest(
            fileName: "get-game",
            sha256Hex: "e22ac8ec7dc35540bfb10ce1df5f97f208a8ef11c40f2dd9db32f5181c6a7671"
        ),
        VendoredFixtureDigest(
            fileName: "investigator-unhealed-horror-negative",
            sha256Hex: "46aca1c80dd8d592d03a5adf0a0824510ea7f3877839a8bfc114babc30be5643"
        ),
        VendoredFixtureDigest(
            fileName: "location-enemy-view",
            sha256Hex: "a17406992baa5ebb02c216c56bae7205804e6d20544c1ea08fa82aa1e6af348b"
        ),
        VendoredFixtureDigest(
            fileName: "manifest",
            sha256Hex: "5ba1e91cda84b59eeed2e33b027f3b2db4333d7e615cc18981df3f81c9772b06"
        ),
        VendoredFixtureDigest(
            fileName: "mode-campaign-only",
            sha256Hex: "0a5e645bf7f4fd7399048a934d36c2021627bed8663e8f7916c67d132a5cceea"
        ),
        VendoredFixtureDigest(
            fileName: "mode-campaign-scenario",
            sha256Hex: "05a06d8c3d6a56e2014df7696b8c35af1d5f07dc86f596111c0867389bcd44ed"
        ),
        VendoredFixtureDigest(
            fileName: "mode-turn-zero",
            sha256Hex: "f24f746d33ebb36ed75f0263047f0340515652c01ca976a4c94a6a3d2877d839"
        ),
        VendoredFixtureDigest(
            fileName: "movement",
            sha256Hex: "c284c0b4244024a072ee7a486c5907db4981c6ff4fed1d55cbe33046fb0b63dc"
        ),
        VendoredFixtureDigest(
            fileName: "public-game-structured-log",
            sha256Hex: "9de1b601091ed9063ab0b3b67601851b2ffa1a4592324bb9aaace1ea7c61ec87"
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
            fileName: "question-choose-one",
            sha256Hex: "854d6a2891155ff4da9e075224d4cd5a7519e4e4cb2ec659a740c872f8b799fc"
        ),
        VendoredFixtureDigest(
            fileName: "question-choose-one-location",
            sha256Hex: "615bc00af5ff5c45377be33f1301e5c1d3892b422da45b3dcc22c3377afab617"
        ),
        VendoredFixtureDigest(
            fileName: "question-choose-one-location-multiple",
            sha256Hex: "25751cccc02dc18de38e0cbebf71acb5303d47df3705367f0c14089853bcbe07"
        ),
        VendoredFixtureDigest(
            fileName: "question-cover-up-reaction",
            sha256Hex: "4de68760c168088464d46affbebedcf0a8dba3ff470a3b2297ba53515fa824a0"
        ),
        VendoredFixtureDigest(
            fileName: "question-encounter-deck-draw",
            sha256Hex: "fb341f57cba32fd0d01e3d67098fa7684cd51b6b2b008c65fea61db5487ac703"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack",
            sha256Hex: "888ab4cf258272dc7ea5ad70cd34dfcff167f409cee2c4a5b0a31d4f906db797"
        ),
        VendoredFixtureDigest(
            fileName: "question-enemy-attack-damage-assignment",
            sha256Hex: "36d20df58661bb583dfbe5350519d164d751f5ddc85924a0f8e2917ce1bbbdff"
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
            fileName: "question-gathering-act-advance",
            sha256Hex: "21eb483b08ca6cc6ad76b3d7884dde7f817cc9da9945e71ab975527c13b7fd6b"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-act-objective",
            sha256Hex: "26435f5874cc374172e1b1c55d515efdf9307ec062f039e840d25e95cf95f224"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-attic-entry-forced",
            sha256Hex: "b0622d1a4d3a546e11efbd64e4ddd4a4d508606ac8ac5ec55b1e732188fc6029"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-attic-horror-assignment",
            sha256Hex: "9241df0b7a57a5be5d0d2c35b47635ba39823a6179b018ce730a8e124bb3f6b3"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-cellar-damage-assignment",
            sha256Hex: "1d746cbaa060ef427516d1b949c2e40600c19a86762a0eb892db1f3ade916473"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-cellar-entry-forced",
            sha256Hex: "ec1efb567e6bc8133ebef8df6b3bb07a85fc77e308d163a96f97e8d6973a0dc9"
        ),
        VendoredFixtureDigest(
            fileName: "question-gathering-movement",
            sha256Hex: "abe2414c791467424d5fbf578b42dca6a2b96ea592838da59462252a6e5bc733"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-choose-amounts",
            sha256Hex: "fc587b6b9962db5bf585ca71524ade287847b121a42bd85d3c0ca09f01f03c73"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-choose-deck",
            sha256Hex: "839049ffb1bf6bc2cf56955b4e9f724e17b8a5bafe48ea25dc245032ccc78194"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-choose-n",
            sha256Hex: "fe4422e28ef55c79ffad0dfcf081b57d4f6eb95fe8108b089a72536bc43f7bdb"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-choose-some",
            sha256Hex: "a91b4852482477c02ff6485c2ebb60970811c4b1eb44c7859456c49d8f75ae4b"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-choose-up-to-n",
            sha256Hex: "870da3ca5c45e95bdd95d69e385e25b3e18d07f3227787cb0cfa6d378c313357"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-cost-ability-window",
            sha256Hex: "62c5375f001322ebd05ba8e10e551aadfaf2e19dd5be7559acb72aed26905606"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-invalid-info",
            sha256Hex: "6ca58559a1a8da1dc1ffd48e542b3b4e3512fc4e34dcbd6a60205ce2dc8c184a"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-one-at-a-time-auto",
            sha256Hex: "a7f5b6b1fc2027ff1ac5ddba7b47a2d6fb39ab376a3252e1cc739385cf4041c6"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-one-from-each",
            sha256Hex: "848e1bc5c694db89f2bc68b5395dbce704dbeac4e94fd167c485d5ed4859e83c"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-payment-amounts",
            sha256Hex: "f72a58a043fa25dfdf28ede236179725e9902663444168a87102c3ad1cc8a277"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-read",
            sha256Hex: "439f4ed45a2d0e9b380a36af4ce9e9f1785acafe622811a6212973d89a7a9a10"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-skill-label",
            sha256Hex: "b1aef3920e49726302603823eedf213ba7a555cd7a0458d79515b01fd609546e"
        ),
        VendoredFixtureDigest(
            fileName: "question-generic-wrapped",
            sha256Hex: "8d330117c0a48b2cea42d9ed68e2e823370535e12b5b0c70d2cf217fe846f446"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-apply-results",
            sha256Hex: "ca3834a719c64a263c31982cfb5987c08da40ec3494d2380ccffaebb46e11774"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-commit",
            sha256Hex: "0cef8bb88be1ac2feb7cd2d37b952bf54fa47b4ea7d83474326baf9da7fb9b18"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-fast-window",
            sha256Hex: "6ae49986f27c9ab934ddd53b08e2dd6c3fa33a85a2ee258409c0321332ed731b"
        ),
        VendoredFixtureDigest(
            fileName: "question-investigate-reveal-window",
            sha256Hex: "6ae49986f27c9ab934ddd53b08e2dd6c3fa33a85a2ee258409c0321332ed731b"
        ),
        VendoredFixtureDigest(
            fileName: "question-mulligan",
            sha256Hex: "88249e7206671dbb5f43a8187c9fa6e0cbbee1859e06957ca1a454455d156029"
        ),
        VendoredFixtureDigest(
            fileName: "question-player-window-choose-one",
            sha256Hex: "f0819c56cdc88736add32ea61c87404043b57d88b8bebd8043495c5f934f164e"
        ),
        VendoredFixtureDigest(
            fileName: "question-player-window-enemy-actions",
            sha256Hex: "07c94499fc8dd2ad167dd19d0f16219302dee3ff8629b585008ad2f7510f237f"
        ),
        VendoredFixtureDigest(
            fileName: "question-player-window-engage-action",
            sha256Hex: "523da05a971f6c6173060aa37004de2f7b046b17e2571f4ca9cc09eaa327cc12"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-encounter-deck-draw",
            sha256Hex: "81af695fe229f59dd631dda136086baeec6047b334b42cc135160f925ae42f6d"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-act-advance",
            sha256Hex: "1e2dc53385e49a67a6bcee0fcb9f9b2d203e23f57de8a7db7195239e4d9d4dcd"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-act-objective",
            sha256Hex: "30d8835cd49ec2944615eb82669e7cb636a447c79011940f5a31bee9fbb1eff9"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-attic-entry-forced",
            sha256Hex: "1ff2e9976a812c0a3bbbafb143e846194fc0b3e957a0220aa9710762e9790a57"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-attic-horror-assignment",
            sha256Hex: "d9137fdfb93327654c3fc9e1b431d788c4d2f8b660a1e9f62961009c3918067f"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-cellar-damage-assignment",
            sha256Hex: "c8d18ae5a338b525ba6819f127783a1699b6d494aa7ee7d6724b6a8ff9a3e033"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-cellar-entry-forced",
            sha256Hex: "e3b4ccd1e322f625a3611f0f0bac7a1e56c2fcfe80838baf5f8d5bb39fc04cff"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-gathering-movement",
            sha256Hex: "f862281f67a8b9d80c1dc84bbbf7ffc556ae6524452aca1c0654f452d560f770"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-choose-amounts",
            sha256Hex: "386a7ad1e8d3f23d683201bd3fe59d5c7175a19e29c43fd929fb77bf460a5475"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-choose-deck",
            sha256Hex: "262feb493d23bc3c4a49491927006cd7299fe733e05c7237227635dd84ee0480"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-choose-n",
            sha256Hex: "17c80908ee0b16cf73e610851a6818ae4179deb8cdfbddf4ee1c204dbab1346c"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-choose-some",
            sha256Hex: "94e86c8ae3620fd4319d59227c941f7eea9615beea2a94fcffb3c3bdad4724a3"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-choose-up-to-n",
            sha256Hex: "912b862349c1db44e4151920d95e780c75cbac7592c913dcaf0c50bc4c718855"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-cost-ability-window",
            sha256Hex: "66364c46bad7a04a49426c69f78ba70f67792b04a5e828e9c150336fc0155418"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-invalid-info",
            sha256Hex: "be93995e75bdec258df9e9de35e51b670fe6f09e087454db482be1428c173034"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-one-at-a-time-auto",
            sha256Hex: "8767491be9558be4b07481ea32c36f1e1c813226472c85feb9187e9c898c628d"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-one-from-each",
            sha256Hex: "4e8d95c7a556e90c1ac60a612dd6b214d882aac3467d27d41d2811344bca48e9"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-payment-amounts",
            sha256Hex: "36ed7d650080f463fa2868e0e105a58e769228389d80184bd6abb269f939a2fb"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-read",
            sha256Hex: "4be412a3141f16035e380c6bd3994fa578804293c6df4fb541643c83d54b937c"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-skill-label",
            sha256Hex: "94b3beab6799f70c876fba203d8a892d6f769de2c38984ac83916521b0f19b2f"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-generic-wrapped",
            sha256Hex: "75595d9f8bda5a779b6409963ce060b8d9049568f2b4ed58d484e59507f096e8"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-representatives",
            sha256Hex: "5286d86aac815dcd931a4eb665c585126313fdb19037bff508acb2f471f9ad79"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-representatives.schema",
            sha256Hex: "9c0cc63da26781a4a78e76433395437d05a5859b628c647dcac5d1d1438fdddf"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation-treachery-forced-ability",
            sha256Hex: "458815ac4e9cd27a5b90db9ac038b99d90de7de13f9b341c75b49e5a53753b3c"
        ),
        VendoredFixtureDigest(
            fileName: "question-presentation.schema",
            sha256Hex: "a960f4c588c7b44a660ac2c507de3c84c3341499adca18e181166da87a827ff6"
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
            fileName: "question-roland-defeat-reaction",
            sha256Hex: "3b4c5fa95e172f10edbfb81f990e75a38fe0c9f401e86d02b2a293a580d17127"
        ),
        VendoredFixtureDigest(
            fileName: "question-round-end-forced-ability",
            sha256Hex: "9441f141605642ce4d0d69c1aab05e5b0d7ce39202d7872c1ed52293004331ed"
        ),
        VendoredFixtureDigest(
            fileName: "question-treachery-forced-ability",
            sha256Hex: "7ddeee49948feb86c56b6a44fbf85cb2d3e4d0b90c64f03a23d663093a04ae34"
        ),
        VendoredFixtureDigest(
            fileName: "question-window-choose-one",
            sha256Hex: "96058cb5e2bb8a1d3beb5107b08fb66b8b4be8eb648317d439c5859657e362f6"
        ),
        VendoredFixtureDigest(
            fileName: "raw-question-fixture.schema",
            sha256Hex: "cdc83061a2631f80942b5608529d5ebe0037e4a40630476fc81d2ac942ddd692"
        ),
        VendoredFixtureDigest(
            fileName: "replay-attestation",
            sha256Hex: "b445a7ed2b139cac64f5835136e4cdbdf0d648f8df1b64fc45b634f7bc20c3ac"
        ),
        VendoredFixtureDigest(
            fileName: "replay-attestation.schema",
            sha256Hex: "ce0a95eb11996ed95ddc47e92a2071202e6ff01d8ff9cf0d352dd13e24739194"
        ),
        VendoredFixtureDigest(
            fileName: "uuid-entity-map",
            sha256Hex: "09ebbcb0bffbcfac4060c878976570b965f10b70a2597111b162662b56b7763d"
        ),
        VendoredFixtureDigest(
            fileName: "room-closed",
            sha256Hex: "fabfe52fd38ab86c7c210c681205d6aa2c992200a798063b982ba0a0aefcfae6"
        ),
    ]
}

// swiftlint:enable file_length type_body_length
