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
}

extension ServerCapabilities: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaRevision
        case status
        case apiBasePath
        case nativeClientMinimumRevision
        case capabilities
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
        capabilities = Set(capabilitiesArray)
    }
}
