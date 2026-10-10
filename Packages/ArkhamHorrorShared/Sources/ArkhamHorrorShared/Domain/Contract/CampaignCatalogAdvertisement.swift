import Foundation

/// The optional campaign-catalog pointer a server publishes in `GET /api/v1/capabilities`.
///
/// The create-game loader derives the endpoint from the selected `ServerProfile` and the
/// current contract pin; this advertisement is still decoded so malformed or unpaired
/// capability metadata fails closed at the capability boundary, matching the locale-catalog
/// pointer policy.
struct CampaignCatalogAdvertisement: Sendable, Equatable, Hashable {
    static let capabilityIdentifier = "arkham.campaign-catalog.v1"

    let endpoint: String
    let catalogRevision: String
    let schemaVersion: String
    let digestAlgorithm: String

    static func decode(from raw: JSONValue) -> CampaignCatalogAdvertisement? {
        guard case let .object(object) = raw else { return nil }
        let required: Set = ["endpoint", "catalogRevision", "schemaVersion", "digestAlgorithm"]
        guard Set(object.keys) == required,
              case let .string(endpoint)? = object["endpoint"],
              endpoint == "/api/v1/arkham/campaign-catalog",
              case let .string(catalogRevision)? = object["catalogRevision"],
              LocaleCatalogGrammar.isCatalogRevision(catalogRevision),
              case let .string(schemaVersion)? = object["schemaVersion"],
              schemaVersion == "1.0.0",
              case let .string(digestAlgorithm)? = object["digestAlgorithm"],
              digestAlgorithm == "sha256"
        else { return nil }
        return CampaignCatalogAdvertisement(
            endpoint: endpoint,
            catalogRevision: catalogRevision,
            schemaVersion: schemaVersion,
            digestAlgorithm: digestAlgorithm
        )
    }
}
