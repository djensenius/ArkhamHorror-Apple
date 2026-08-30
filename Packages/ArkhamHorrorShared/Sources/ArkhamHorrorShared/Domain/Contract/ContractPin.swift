/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49
/// - Backend commit: `ee6efffa4d7a49f2ac7bf6b9349802d3d7675ae5`
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
    /// Pinned to backend commit `ee6efffa` (through PR #49), which adds the governed
    /// basic-choice prompt and Answer contracts and advances schema to `0.1.21`.
    static let current = ContractPin(
        backendCommit: "ee6efffa4d7a49f2ac7bf6b9349802d3d7675ae5",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 21),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 21),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
    )
}
