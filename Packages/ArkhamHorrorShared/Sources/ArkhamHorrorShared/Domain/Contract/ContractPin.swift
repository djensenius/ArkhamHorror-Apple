/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49, #51, #57, #62, #65
/// - Backend commit: `c7e24d23f5ef992038802d9fb28ceb8fc8121ccf`
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
    /// Pinned to backend commit `c7e24d23` (through PR #65), which governs the production
    /// opening mulligan question and advances schema to `0.1.28`.
    static let current = ContractPin(
        backendCommit: "c7e24d23f5ef992038802d9fb28ceb8fc8121ccf",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 28),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 28),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
    )
}
