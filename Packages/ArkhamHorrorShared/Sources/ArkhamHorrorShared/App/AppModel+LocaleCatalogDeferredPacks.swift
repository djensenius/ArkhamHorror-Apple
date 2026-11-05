import Foundation

/// The deferred-pack (card names) load for one published snapshot.
struct LocaleCatalogDeferredPackLoad: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case loading
        case loaded
        /// Sticky: a re-render does not refetch. Cleared by ``AppModel/retryLocaleCatalog()``
        /// or a new catalog request.
        case failed
    }

    let identity: LocaleCatalogIdentity
    let state: State
}

extension AppModel {
    /// Loads the published snapshot's deferred packs (card names) once, on the first
    /// `cardNames.*` miss. Concurrent demands coalesce onto one load per snapshot identity,
    /// and a failure is not retried on re-render. Until it completes, and after a failure,
    /// labels keep the server-sent name; ``localeCatalogFailure`` is never set by it.
    func loadLocaleCatalogDeferredPacks() {
        guard let snapshot = localeCatalog,
              snapshot.hasPendingDeferredPacks,
              let request = localeCatalogRequest,
              request.profileID == selectedProfile.id,
              request.advertisement.catalogRevision == snapshot.identity.catalogRevision,
              request.advertisement.manifestSha256 == snapshot.identity.manifestSha256,
              localeCatalogDeferredPacks?.identity != snapshot.identity
        else { return }
        let identity = snapshot.identity
        localeCatalogDeferredPacks = LocaleCatalogDeferredPackLoad(
            identity: identity, state: .loading
        )
        let loader = localeCatalogLoader
        let profile = selectedProfile
        localeCatalogDeferredPackTask?.cancel()
        localeCatalogDeferredPackTask = Task { [weak self] in
            let result = await loader.loadDeferredPacks(
                for: snapshot, advertisement: request.advertisement, profile: profile
            )
            self?.applyLocaleCatalogDeferredPacks(result, request: request, identity: identity)
        }
    }

    /// Publishes a deferred-pack load with one assignment of the whole augmented snapshot,
    /// but only while the same request and snapshot identity are still current.
    func applyLocaleCatalogDeferredPacks(
        _ result: Result<LocaleCatalogSnapshot, LocaleCatalogFailure>,
        request: LocaleCatalogRequest,
        identity: LocaleCatalogIdentity
    ) {
        guard !Task.isCancelled,
              localeCatalogRequest == request,
              localeCatalog?.identity == identity,
              localeCatalogDeferredPacks == LocaleCatalogDeferredPackLoad(
                  identity: identity, state: .loading
              )
        else { return }
        localeCatalogDeferredPackTask = nil
        guard case let .success(loaded) = result,
              loaded.identity == identity,
              !loaded.hasPendingDeferredPacks
        else {
            localeCatalogDeferredPacks = LocaleCatalogDeferredPackLoad(
                identity: identity, state: .failed
            )
            return
        }
        localeCatalogDeferredPacks = LocaleCatalogDeferredPackLoad(
            identity: identity, state: .loaded
        )
        localeCatalog = loaded
    }

    func resetLocaleCatalogDeferredPacks() {
        localeCatalogDeferredPackTask?.cancel()
        localeCatalogDeferredPackTask = nil
        localeCatalogDeferredPacks = nil
    }
}
