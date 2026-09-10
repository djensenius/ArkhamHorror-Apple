/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49, #51, #57, #62, #65, #66, #68, #70
/// - Backend commit: `33b5bdc5cef6eff57d0b8d4446b1279829892452`
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
    /// PR #70 merge commit `33b5bdc` governs the production enemy attack at revision
    /// `0.1.31`.
    static let current = ContractPin(
        backendCommit: "33b5bdc5cef6eff57d0b8d4446b1279829892452",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 31),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 31),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
    )
}
