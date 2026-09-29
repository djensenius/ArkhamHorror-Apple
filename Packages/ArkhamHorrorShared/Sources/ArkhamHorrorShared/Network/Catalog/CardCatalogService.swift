import Foundation

struct CardCatalogSnapshot: Sendable, Equatable {
    let namesByCode: [CardCode: CardName]

    func displayName(for code: CardCode) -> String? {
        namesByCode[code].map {
            BoardDisplayFormatting.safeTitle($0, fallback: code.rawValue)
        }
    }
}

struct CardCatalogService: Sendable {
    let transport: any LocaleCatalogTransporting
    private static let maxBytes = 8 * 1024 * 1024

    init(transport: any LocaleCatalogTransporting = URLSessionLocaleCatalogTransport()) {
        self.transport = transport
    }

    func load(
        on profile: ServerProfile
    ) async -> Result<CardCatalogSnapshot, LocaleCatalogFailure> {
        do {
            let builtIn = try await fetch(path: "/arkham/cards", queryItems: [
                URLQueryItem(name: "cardPool", value: "both"),
            ], on: profile)
            let homebrew = try await fetch(path: "/arkham/homebrew/cards", on: profile)
            var namesByCode: [CardCode: CardName] = [:]
            for card in builtIn + homebrew {
                namesByCode[card.cardCode] = card.name
            }
            return .success(CardCatalogSnapshot(namesByCode: namesByCode))
        } catch let failure as LocaleCatalogFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(.transportFailure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private func fetch(
        path: String,
        queryItems: [URLQueryItem] = [],
        on profile: ServerProfile
    ) async throws -> CardList {
        let base = profile.endpointURL(path: path, pin: .current)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw LocaleCatalogFailure.unresolvableManifestURL
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw LocaleCatalogFailure.unresolvableManifestURL }
        let response = try await transport.fetch(url, maxBytes: Self.maxBytes)
        guard response.url == url else { throw LocaleCatalogFailure.redirected }
        guard response.statusCode == 200 else {
            throw LocaleCatalogFailure.unexpectedStatus(response.statusCode)
        }
        guard LocaleCatalogLoader.isAcceptableJSONMediaType(response) else {
            throw LocaleCatalogFailure.unacceptableContentType
        }
        return try ContractJSON.decode(CardList.self, from: response.data)
    }
}
