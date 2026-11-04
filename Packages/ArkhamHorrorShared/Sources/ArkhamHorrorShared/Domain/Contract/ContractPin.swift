/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49, #51, #57,
///   #62, #65, #66, #68, #70, #72, #75, #76, #78, #79, #81, #83, #85, #87, #89, #91,
///   #93, #95, #98, #99, #101, #124, #125, #129, #130, #135, #140, #152, #159, #168,
///   #219, #247, #269, #281, #287, #300, #303, #304
/// - Backend commit: 05e537101118c5f8ceb70abae82ab7f59a355d93
struct ContractPin: Sendable {
    /// The backend git commit this client was built against.
    let backendCommit: String
    /// The contract schema revision this client bundle decodes.
    ///
    /// Used in the client-too-old check: if this value is below the server's
    /// `nativeClientMinimumRevision`, the client must be updated.
    let supportedSchemaRevision: ContractRevision
    /// Minimum server schema revision this client requires.
    let minimumServerSchemaRevision: ContractRevision
    /// Expected API base path (e.g. `"/api/v1"`).
    let expectedApiBasePath: String
    /// The `nativeClientMinimumRevision` recorded from the canonical source fixture at pin time.
    ///
    /// Used in drift assertions to detect fixture drift between the pin and the current server
    /// contract. If the server changes this value without a corresponding pin update, tests fail.
    let sourceNativeClientMinimumRevision: ContractRevision
}

extension ContractPin {
    /// The canonical pin compiled into this client build.
    ///
    /// Contract revision `0.1.63` (djensenius/ArkhamHorror#304) adds the locale-catalog
    /// `cardNames` packs (0.1.60) and the card-only locales (0.1.63); 0.1.58-0.1.63 change no route
    /// or wire shape, and the server's native floor stays `0.1.57`. Revision
    /// `0.1.57` (the upstream sync, djensenius/ArkhamHorror#247) added
    /// `labelCards` on labels, optional board fields, `ChooseFromCollection`, new socket
    /// messages and the maintenance 503. The app still only requires server revision
    /// `0.1.48`, which introduced `AnswerRejected`: the label decoders accept both the
    /// legacy `card` and the new `labelCards` shape, the new board fields are optional,
    /// ArkhamDB linking and write-back are capability-gated, a missing `deckLinks` key
    /// (0.1.54) decodes as empty, and the 0.1.53 dual-shape decoders still accept legacy
    /// `forceDraw` strings/null and log strings from 0.1.48-0.1.52 servers.
    static let current = ContractPin(
        backendCommit: "05e537101118c5f8ceb70abae82ab7f59a355d93",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 63),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 48),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 57)
    )
}
