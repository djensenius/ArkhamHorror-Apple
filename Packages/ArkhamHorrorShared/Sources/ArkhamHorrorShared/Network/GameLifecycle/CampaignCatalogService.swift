import Foundation

/// Errors from loading the optional server-authored create-game catalog.
enum CampaignCatalogLoadFailure: Error, Equatable, Sendable {
    case unexpectedStatus(Int)
    case nonHTTPResponse
    case transportFailure
    case malformedAdvertisement
    case malformedCatalog
    case tooLarge

    var message: String {
        switch self {
        case .malformedAdvertisement, .malformedCatalog:
            gameLifecycleLocalized(
                "create.catalog.failure.malformed",
                "The server campaign catalog could not be decoded. Showing the built-in starter catalog." // swiftlint:disable:this line_length
            )
        case .tooLarge:
            gameLifecycleLocalized(
                "create.catalog.failure.tooLarge",
                "The server campaign catalog is too large. Showing the built-in starter catalog."
            )
        case .transportFailure, .nonHTTPResponse, .unexpectedStatus:
            gameLifecycleLocalized(
                "create.catalog.failure.unavailable",
                "The server campaign catalog is unavailable. Showing the built-in starter catalog."
            )
        }
    }
}

private struct CampaignCatalogCacheKey: Hashable, Sendable {
    let endpoint: String
    let catalogRevision: String
}

private struct CachedCampaignCatalog: Sendable, Equatable {
    let etag: String?
    let catalogRevision: String
    let document: CampaignCatalogDocument
}

private actor CampaignCatalogMemoryCache {
    private var entries: [CampaignCatalogCacheKey: CachedCampaignCatalog] = [:]

    func entry(for key: CampaignCatalogCacheKey) -> CachedCampaignCatalog? {
        entries[key]
    }

    func store(_ entry: CachedCampaignCatalog, for key: CampaignCatalogCacheKey) {
        entries[key] = entry
    }
}

/// Public, unauthenticated loader for `GET /api/v1/arkham/campaign-catalog`.
///
/// The endpoint is advertised by `arkham.campaign-catalog.v1`. It supports weak ETags and
/// `If-None-Match`; a 304 response reuses the cached document, while a 200 response is decoded
/// from its exact captured bytes and cached under the advertised endpoint and
/// `catalogRevision`.
struct CampaignCatalogService: Sendable {
    private static let maxBytes = 4 * 1024 * 1024

    private let transport: any LocaleCatalogTransporting
    private let pin: ContractPin
    private let cache: CampaignCatalogMemoryCache

    init(
        transport: any LocaleCatalogTransporting = URLSessionLocaleCatalogTransport(),
        pin: ContractPin = .current
    ) {
        self.transport = transport
        self.pin = pin
        cache = CampaignCatalogMemoryCache()
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func load(
        on profile: ServerProfile,
        advertisement: CampaignCatalogAdvertisement
    ) async throws -> CampaignCatalogDocument {
        guard advertisement.endpoint == "/api/v1/arkham/campaign-catalog" else {
            throw CampaignCatalogLoadFailure.malformedAdvertisement
        }
        let url = profile.endpointURL(path: "/arkham/campaign-catalog", pin: pin)
        let key = CampaignCatalogCacheKey(
            endpoint: url.absoluteString,
            catalogRevision: advertisement.catalogRevision
        )
        let cached = await cache.entry(for: key)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let response: LocaleCatalogResponse
        do {
            response = try await transport.fetch(request, maxBytes: Self.maxBytes)
        } catch let failure as CampaignCatalogLoadFailure {
            throw failure
        } catch let failure as LocaleCatalogFailure {
            switch failure {
            case .tooLarge:
                throw CampaignCatalogLoadFailure.tooLarge
            default:
                throw CampaignCatalogLoadFailure.transportFailure
            }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw CampaignCatalogLoadFailure.transportFailure
        }
        try Task.checkCancellation()

        switch response.statusCode {
        case 304:
            if let cached {
                return cached.document
            }
            throw CampaignCatalogLoadFailure.unexpectedStatus(304)
        case 200 ... 299:
            guard response.data.count <= Self.maxBytes else {
                throw CampaignCatalogLoadFailure.tooLarge
            }
            let document: CampaignCatalogDocument
            do {
                document = try ContractJSON.decode(CampaignCatalogDocument.self, from: response.data)
            } catch {
                try Task.checkCancellation()
                throw CampaignCatalogLoadFailure.malformedCatalog
            }
            guard document.catalogRevision == advertisement.catalogRevision else {
                throw CampaignCatalogLoadFailure.malformedCatalog
            }
            await cache.store(
                CachedCampaignCatalog(
                    etag: response.etag,
                    catalogRevision: document.catalogRevision,
                    document: document
                ),
                for: key
            )
            return document
        default:
            throw CampaignCatalogLoadFailure.unexpectedStatus(response.statusCode)
        }
    }
}
