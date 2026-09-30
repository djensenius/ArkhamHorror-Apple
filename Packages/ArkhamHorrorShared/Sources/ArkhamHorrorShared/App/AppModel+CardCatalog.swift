import Foundation

extension AppModel {
    func clearCardCatalogCache() {
        cardCatalogTask?.cancel()
        cardCatalogTask = nil
        cardCatalogGeneration += 1
        cardCatalog = nil
        cardCatalogFailure = nil
        isCardCatalogLoading = false
    }

    func loadCardCatalogIfNeeded() {
        guard cardCatalog == nil, !isCardCatalogLoading else { return }
        cardCatalogGeneration += 1
        let requestGeneration = cardCatalogGeneration
        isCardCatalogLoading = true
        cardCatalogFailure = nil
        let profile = selectedProfile
        let service = cardCatalogService
        cardCatalogTask = Task { [weak self] in
            do {
                let snapshot = try await service.load(on: profile)
                await MainActor.run {
                    self?.applyCardCatalogResult(
                        .success(snapshot), profileID: profile.id,
                        requestGeneration: requestGeneration
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.applyCardCatalogCancellation(
                        profileID: profile.id,
                        requestGeneration: requestGeneration
                    )
                }
            } catch let failure as LocaleCatalogFailure {
                await MainActor.run {
                    self?.applyCardCatalogResult(
                        .failure(failure), profileID: profile.id,
                        requestGeneration: requestGeneration
                    )
                }
            } catch {
                await MainActor.run {
                    self?.applyCardCatalogResult(
                        .failure(.malformedJSON), profileID: profile.id,
                        requestGeneration: requestGeneration
                    )
                }
            }
        }
    }

    func applyCardCatalogResult(
        _ result: Result<CardCatalogSnapshot, LocaleCatalogFailure>,
        profileID: UUID,
        requestGeneration: Int
    ) {
        guard isCurrentCardCatalogRequest(profileID: profileID, generation: requestGeneration)
        else { return }
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

    private func applyCardCatalogCancellation(profileID: UUID, requestGeneration: Int) {
        guard isCurrentCardCatalogRequest(profileID: profileID, generation: requestGeneration)
        else { return }
        isCardCatalogLoading = false
        cardCatalogTask = nil
    }

    private func isCurrentCardCatalogRequest(profileID: UUID, generation: Int) -> Bool {
        generation == cardCatalogGeneration && profileID == selectedProfile.id
    }
}
