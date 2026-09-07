/// Capabilities advertised by the server at `GET /api/v1/capabilities`.
///
/// Unknown future capability strings are preserved in ``capabilities``; this type
/// intentionally does not fail on unrecognised values (open-string identifiers).
/// Unknown status values are similarly preserved in ``status``.
struct ServerCapabilities: Equatable, Sendable {
    let schemaRevision: ContractRevision
    let status: ContractStatus
    let apiBasePath: String
    let nativeClientMinimumRevision: ContractRevision
    /// Open-string capability identifiers. Unknown future values are preserved without error.
    let capabilities: Set<String>
    /// The optional, additive locale-catalog pointer, present only when it is paired with
    /// `i18n.locale-catalog.v1` *and* fully satisfies the governed schema.
    ///
    /// The backend produces the object and its capability string from one `Maybe`, so a client
    /// can never legitimately see one without the other, and `capabilities.schema.json` states
    /// that pairing in both directions. This client therefore requires the pairing in both
    /// directions too: an object without the identifier, an identifier without the object, or
    /// an object this client refused to parse all yield `nil` -- the same value a deployment
    /// that publishes no catalog produces.
    ///
    /// Deliberately fail-closed rather than fatal. An unpaired or malformed pointer must not
    /// make the *whole* capabilities response unusable (every other field is still exactly
    /// what the contract promises, and the response is what sign-in itself negotiates on), but
    /// it must never produce a catalog fetch either, because a client that proceeded here
    /// would be trusting half an advertisement.
    let localeCatalog: LocaleCatalogAdvertisement?

    init(
        schemaRevision: ContractRevision,
        status: ContractStatus,
        apiBasePath: String,
        nativeClientMinimumRevision: ContractRevision,
        capabilities: Set<String>,
        localeCatalog: LocaleCatalogAdvertisement? = nil
    ) {
        self.schemaRevision = schemaRevision
        self.status = status
        self.apiBasePath = apiBasePath
        self.nativeClientMinimumRevision = nativeClientMinimumRevision
        self.capabilities = capabilities
        self.localeCatalog = localeCatalog
    }
}

extension ServerCapabilities: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaRevision
        case status
        case apiBasePath
        case nativeClientMinimumRevision
        case capabilities
        case localeCatalog
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaRevision = try container.decode(ContractRevision.self, forKey: .schemaRevision)
        status = try container.decode(ContractStatus.self, forKey: .status)
        apiBasePath = try container.decode(String.self, forKey: .apiBasePath)
        nativeClientMinimumRevision = try container.decode(
            ContractRevision.self,
            forKey: .nativeClientMinimumRevision
        )
        let capabilitiesArray = try container.decode([String].self, forKey: .capabilities)
        let identifiers = Set(capabilitiesArray)
        guard identifiers.count == capabilitiesArray.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .capabilities,
                in: container,
                debugDescription: "capabilities must not contain duplicate identifiers"
            )
        }
        capabilities = identifiers
        let raw = try container.decodeIfPresent(JSONValue.self, forKey: .localeCatalog)
        let advertised = identifiers.contains(LocaleCatalogLimits.capabilityIdentifier)
        localeCatalog = if advertised, let raw {
            LocaleCatalogAdvertisement.decode(from: raw)
        } else {
            nil
        }
    }
}
