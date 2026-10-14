/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49, #51, #57,
///   #62, #65, #66, #68, #70, #72, #75, #76, #78, #79, #81, #83, #85, #87, #89, #91,
///   #93, #95, #98, #99, #101, #124, #125, #129, #130, #135, #140, #152, #159
/// - Backend commit: 06d5df29d991cc69c83637b1833be81045e8b113
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
    /// Contract revision `0.1.53` adds structured log rows, array-valued `forceDraw`,
    /// `RoomClosed`, and identified broken-game rows. The app still only requires server
    /// revision `0.1.48`, which introduced `AnswerRejected`: the 0.1.53 decoders remain
    /// tolerant of 0.1.48-0.1.52 wire shapes (`forceDraw` string/null and legacy log strings),
    /// so the same app build can continue to talk to the owner's self-hosted 0.1.52 server
    /// and the public server while also accepting 0.1.53.
    static let current = ContractPin(
        backendCommit: "06d5df29d991cc69c83637b1833be81045e8b113",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 53),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 48),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 53)
    )
}
