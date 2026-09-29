extension AppModel {
    func clearCardCatalogCache() {
        cardCatalogTask?.cancel()
        cardCatalogTask = nil
        cardCatalog = nil
        cardCatalogFailure = nil
        isCardCatalogLoading = false
    }

    func loadCardCatalogIfNeeded() {
        guard cardCatalog == nil, !isCardCatalogLoading else { return }
        isCardCatalogLoading = true
        cardCatalogFailure = nil
        let profile = selectedProfile
        let service = cardCatalogService
        cardCatalogTask = Task { [weak self] in
            let result = await service.load(on: profile)
            await MainActor.run {
                self?.applyCardCatalogResult(result)
            }
        }
    }

    private func applyCardCatalogResult(
        _ result: Result<CardCatalogSnapshot, LocaleCatalogFailure>
    ) {
        isCardCatalogLoading = false
        cardCatalogTask = nil
        switch result {
        case let .success(snapshot):
            cardCatalog = snapshot
            cardCatalogFailure = nil
        case let .failure(failure):
            cardCatalog = nil
            cardCatalogFailure = failure
        }
    }
}
