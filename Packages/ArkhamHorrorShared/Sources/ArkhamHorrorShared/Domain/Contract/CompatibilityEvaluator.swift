/// The outcome of a contract compatibility evaluation.
enum CompatibilityOutcome: Equatable, Sendable {
    /// Client and server are mutually compatible; the server's capability set is included,
    /// together with the optional locale-catalog pointer that came with it.
    ///
    /// The pointer travels with the capability set rather than in a separate lookup because
    /// the two are one negotiated answer from one endpoint: carrying it here is what binds a
    /// catalog to the exact profile probe that advertised it, so a later profile switch can
    /// never leave a previous server's catalog reachable.
    case compatible(capabilities: Set<String>, localeCatalog: LocaleCatalogAdvertisement?)
    /// Client and server are incompatible for the stated reason.
    case incompatible(reason: CompatibilityRejection)
    /// The capabilities endpoint returned HTTP 404; the server pre-dates the contract.
    ///
    /// Treat conservatively: no modern capabilities are assumed.
    case legacyFallback

    /// A compatible outcome with no advertised catalog: the shape a deployment that publishes
    /// no locale catalog produces, and the one every call site that is not about catalog
    /// discovery uses.
    static func compatible(capabilities: Set<String>) -> CompatibilityOutcome {
        .compatible(capabilities: capabilities, localeCatalog: nil)
    }
}

/// The specific reason a ``CompatibilityOutcome/incompatible(reason:)`` was produced.
enum CompatibilityRejection: Equatable, Sendable {
    /// The client's supported schema revision is below the server's declared minimum.
    case clientTooOld(clientSupports: ContractRevision, serverRequires: ContractRevision)
    /// The server's schema revision is below the client's required minimum.
    case serverTooOld(serverRevision: ContractRevision, clientRequires: ContractRevision)
    /// The server's API base path does not match the expected path.
    case apiBasePathMismatch(server: String, expected: String)
}

/// Evaluates whether a server's capabilities are compatible with this client's contract pin.
///
/// Pure: no I/O, no URLSession, no side effects. Safe to unit-test directly.
struct CompatibilityEvaluator: Sendable {
    let pin: ContractPin
    /// The first backend contract revision that governs `localeCatalog`.
    ///
    /// Catalog authority is gated by the *server's* schema revision so an additive field
    /// received from a pre-governance server can never become a trusted download authority.
    static let localeCatalogSchemaRevision = ContractRevision.literal(
        major: 0, minor: 1, patch: 23
    )

    /// Evaluates the decoded server capabilities against the compiled-in ``ContractPin``.
    ///
    /// Checks (in order):
    /// 1. `pin.supportedSchemaRevision` ≥ server's `nativeClientMinimumRevision`
    /// 2. Server schema revision ≥ `pin.minimumServerSchemaRevision`
    /// 3. Server `apiBasePath` matches `pin.expectedApiBasePath`
    ///
    /// Unknown additive capabilities in the server response are forwarded unchanged
    /// in the ``CompatibilityOutcome/compatible(capabilities:)`` result.
    func evaluate(_ serverCapabilities: ServerCapabilities) -> CompatibilityOutcome {
        guard pin.supportedSchemaRevision >= serverCapabilities.nativeClientMinimumRevision else {
            return .incompatible(reason: .clientTooOld(
                clientSupports: pin.supportedSchemaRevision,
                serverRequires: serverCapabilities.nativeClientMinimumRevision
            ))
        }
        guard serverCapabilities.schemaRevision >= pin.minimumServerSchemaRevision else {
            return .incompatible(reason: .serverTooOld(
                serverRevision: serverCapabilities.schemaRevision,
                clientRequires: pin.minimumServerSchemaRevision
            ))
        }
        guard serverCapabilities.apiBasePath == pin.expectedApiBasePath else {
            return .incompatible(reason: .apiBasePathMismatch(
                server: serverCapabilities.apiBasePath,
                expected: pin.expectedApiBasePath
            ))
        }
        let catalog = serverCapabilities.schemaRevision >= Self.localeCatalogSchemaRevision
            ? serverCapabilities.localeCatalog
            : nil
        return .compatible(
            capabilities: serverCapabilities.capabilities,
            localeCatalog: catalog
        )
    }

    /// Returns the conservative legacy fallback outcome for use when the server
    /// returns HTTP 404 for the capabilities endpoint.
    ///
    /// Represents a pre-contract server; no modern capabilities are assumed.
    func legacyFallback() -> CompatibilityOutcome {
        .legacyFallback
    }
}
