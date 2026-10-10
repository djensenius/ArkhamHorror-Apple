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
        guard case let .signedIn(profile, compatibility, user) = sessionState else {
            return CreateGameCatalogLoadResult(catalog: .default, warningMessage: nil)
        }
        guard compatibility.modernCapabilities.contains(
            ServerCompatibility.campaignCatalogCapability
        ) else {
            return CreateGameCatalogLoadResult(
                catalog: .default,
                warningMessage: CampaignCatalogLoadFailure.unsupportedServer.message
            )
        }
        guard let advertisement = compatibility.campaignCatalogAdvertisement else {
            return CreateGameCatalogLoadResult(
                catalog: .default,
                warningMessage: CampaignCatalogLoadFailure.malformedAdvertisement.message
            )
        }
        do {
            let resolver = await localeCatalogResolverForCreateGameCatalog(profileID: profile.id)
            let document = try await campaignCatalogService.load(on: profile, advertisement: advertisement) // swiftlint:disable:this line_length
            let catalog = CreateGameCatalog.from(
                document: document,
                resolver: resolver,
                includeBeta: user.beta
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

    private func localeCatalogResolverForCreateGameCatalog(
        profileID: UUID
    ) async -> LocaleCatalogResolver? {
        if let resolver = localeCatalogResolver {
            return resolver
        }
        guard isLocaleCatalogLoading,
              localeCatalogRequest?.profileID == profileID,
              let task = localeCatalogTask
        else {
            return localeCatalogResolver
        }
        await task.value
        return localeCatalogResolver
    }
}

extension ServerCompatibility {
    static let campaignCatalogCapability = "arkham.campaign-catalog.v1"
}
