import Foundation

extension AppModel {
    /// Construction is retried only until it succeeds. Every window then observes
    /// the same cache, including after a profile switch or a source-only retry.
    @discardableResult
    func prepareStoryAssetCache() -> Bool {
        if assetCacheService == nil {
            assetCacheService = assetCacheFactory()
        }
        return assetCacheService != nil
    }

    var storyAssetUnavailability: StoryUnavailableReason {
        guard assetCacheService != nil else { return .imagePipelineUnavailable }
        return storyAssetSourceFailure.map { .catalog($0) } ?? .imageSourceLoading
    }

    var localeCatalogRetryReason: StoryUnavailableReason? {
        if let failure = localeCatalogFailure {
            return failure.isRetryable ? .catalog(failure) : nil
        }
        guard localeCatalog != nil else { return nil }
        if assetCacheService == nil {
            return .imagePipelineUnavailable
        }
        guard let failure = storyAssetSourceFailure, failure.isRetryable else { return nil }
        return .catalog(failure)
    }

    /// Reuses the catalog request's fence without replacing its verified snapshot.
    /// The shared generation also invalidates retry controls in other windows.
    func retryStoryAssetSource(_ request: LocaleCatalogRequest, profile: ServerProfile) {
        localeCatalogTask?.cancel()
        localeCatalogTask = nil
        localeCatalogGeneration += 1
        let catalogGeneration = localeCatalogGeneration
        storyAssetSource = nil
        storyAssetSourceFailure = nil
        guard prepareStoryAssetCache() else { return }
        let loader = storyAssetSourceLoader
        localeCatalogTask = Task { [weak self] in
            let result: Result<AssetSourceNamespace, LocaleCatalogFailure>
            do {
                result = try await .success(loader.load(for: profile))
            } catch is CancellationError {
                return
            } catch {
                result = .failure((error as? LocaleCatalogFailure) ?? .transportFailure)
            }
            self?.applyStoryAssetSourceResult(
                result, request: request, catalogGeneration: catalogGeneration
            )
        }
    }

    func applyStoryAssetSourceResult(
        _ result: Result<AssetSourceNamespace, LocaleCatalogFailure>,
        request: LocaleCatalogRequest,
        catalogGeneration: Int
    ) {
        guard catalogGeneration == localeCatalogGeneration,
              localeCatalogRequest == request,
              request.profileID == selectedProfile.id,
              localeCatalog != nil,
              !Task.isCancelled
        else { return }
        switch result {
        case let .success(source):
            storyAssetSource = source
            storyAssetSourceFailure = nil
        case let .failure(failure):
            storyAssetSource = nil
            storyAssetSourceFailure = failure
        }
    }
}
