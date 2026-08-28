/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PR: djensenius/ArkhamHorror#23
/// - Backend commit: `2bf2935cde121498435744a06fcf63502a80ae43`
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
    /// Pinned to backend commit `2bf2935` (PR #23), which established schema `0.1.11`
    /// and the `GET /api/v1/capabilities` contract.
    static let current = ContractPin(
        backendCommit: "2bf2935cde121498435744a06fcf63502a80ae43",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 11),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 11),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
    )
}
