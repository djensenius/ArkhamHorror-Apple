/// Compiled-in contract metadata pinning this client build to a specific backend revision.
///
/// - Backend PRs: djensenius/ArkhamHorror#20, #22, #24, #45, #49, #51, #57, #62
/// - Backend commit: `d3e4c993776d3417230f8e036b11d64e8289fd62`
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
    /// Pinned to backend commit `d3e4c993` (through PR #62), which governs production
    /// `HeaderEntry` story headings and advances schema to `0.1.27`.
    static let current = ContractPin(
        backendCommit: "d3e4c993776d3417230f8e036b11d64e8289fd62",
        supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 27),
        minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 27),
        expectedApiBasePath: "/api/v1",
        sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
    )
}
