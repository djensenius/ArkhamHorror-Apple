import Foundation

struct CreateGameCatalogLoadResult: Sendable, Equatable {
    let catalog: CreateGameCatalog
    let warningMessage: String?
}

extension AppModel {
    /// Loads the optional server campaign catalog for the create-game sheet.
    ///
    /// If the selected server does not advertise `arkham.campaign-catalog.v1`, the app stays
    /// on the compiled Night of the Zealot catalog. If the server advertises the capability
    /// but the fetch or decode fails, the malformed/unavailable catalog is not trusted; the
    /// same safe starter catalog is returned with an honest warning.
    func createGameCatalogForSheet() async -> CreateGameCatalogLoadResult {
        guard case let .signedIn(profile, compatibility, _) = sessionState,
              compatibility.advertisesCampaignCatalog
        else {
            return CreateGameCatalogLoadResult(catalog: .default, warningMessage: nil)
        }
        do {
            let document = try await campaignCatalogService.load(on: profile)
            let catalog = CreateGameCatalog.from(
                document: document,
                resolver: localeCatalogResolver
            )
            return CreateGameCatalogLoadResult(catalog: catalog, warningMessage: nil)
        } catch is CancellationError {
            return CreateGameCatalogLoadResult(catalog: .default, warningMessage: nil)
        } catch let failure as CampaignCatalogLoadFailure {
            return CreateGameCatalogLoadResult(catalog: .default, warningMessage: failure.message)
        } catch {
            return CreateGameCatalogLoadResult(
                catalog: .default,
                warningMessage: CampaignCatalogLoadFailure.malformedCatalog.message
            )
        }
    }
}

extension ServerCompatibility {
    static let campaignCatalogCapability = "arkham.campaign-catalog.v1"

    var advertisesCampaignCatalog: Bool {
        switch self {
        case let .modern(capabilities):
            capabilities.contains(Self.campaignCatalogCapability)
        case .legacy:
            false
        }
    }
}
