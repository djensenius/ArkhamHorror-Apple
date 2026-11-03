/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49, #51, #57,
///   #62, #65, #66, #68, #70, #72, #75, #76, #78, #79, #81, #83, #85, #87, #89, #91,
///   #93, #95, #98, #99, #101, #124, #125, #129, #130, #135, #140, #152, #159, #168,
///   #219
/// - Backend commit: 9c75088611ca15ee3bbfe0c54b2fa4989b80ed50
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
    /// Contract revision `0.1.55` adds ArkhamDB deck write-back (`deckLinks` on the link
    /// status plus toggle/retry/resolve-conflict endpoints). The app still only requires
    /// server revision `0.1.48`, which introduced `AnswerRejected`: ArkhamDB linking and
    /// write-back are capability-gated, a missing `deckLinks` key (0.1.54) decodes as empty,
    /// and the 0.1.53 dual-shape decoders still accept legacy `forceDraw` strings/null and
    /// log strings from 0.1.48-0.1.52 servers.
    static let current = ContractPin(
        backendCommit: "9c75088611ca15ee3bbfe0c54b2fa4989b80ed50",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 55),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 48),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 53)
    )
}
