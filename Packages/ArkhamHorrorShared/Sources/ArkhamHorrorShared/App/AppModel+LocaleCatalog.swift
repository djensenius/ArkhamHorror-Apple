import Foundation

/// The Apple preferred-language input the catalog's locale selection reads.
///
/// Injectable so tests are deterministic: locale selection must be exercised against a fixed
/// language list, never against whatever the machine running the tests happens to be
/// configured with.
protocol PreferredLanguagesProviding: Sendable {
    var preferredLanguages: [String] { get }
}

/// The production source: the user's own system language preferences, in priority order.
struct SystemPreferredLanguages: PreferredLanguagesProviding {
    var preferredLanguages: [String] {
        Locale.preferredLanguages
    }
}

/// The in-flight or completed catalog request for one server endpoint.
///
/// Holding the advertisement *and* the profile it came from is what makes coalescing safe:
/// two scenes asking for the same catalog observe one load, while a profile switch produces a
/// different request identity and therefore never adopts the previous server's result.
struct LocaleCatalogRequest: Sendable, Equatable {
    let profileID: UUID
    let advertisement: LocaleCatalogAdvertisement
}

extension AppModel {
    /// Installs the catalog pointer negotiated by the probe for `profile`, starting or
    /// coalescing a load.
    ///
    /// Fail-closed in every direction:
    /// - a superseded generation is ignored entirely, so a probe whose profile has already
    ///   been switched away from can never install a catalog for the wrong server;
    /// - `nil` (no advertisement, an unpaired one, or one this client refused to parse) clears
    ///   any existing catalog and records ``LocaleCatalogFailure/notAdvertised``, which keeps
    ///   story keys unresolvable rather than leaving a previous server's catalog reachable;
    /// - an identical request already in flight or already satisfied is a no-op, so multiple
    ///   scenes coalesce onto one immutable load instead of racing several.
    func adoptLocaleCatalogAdvertisement(
        _ advertisement: LocaleCatalogAdvertisement?,
        profile: ServerProfile,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        guard let advertisement else {
            invalidateLocaleCatalog(failure: .notAdvertised)
            return
        }
        let request = LocaleCatalogRequest(profileID: profile.id, advertisement: advertisement)
        guard localeCatalogRequest != request else { return }
        localeCatalogRequest = request
        startLocaleCatalogLoad(request, profile: profile)
    }

    /// Retries a catalog-only transient failure without restarting compatibility, token, or
    /// profile flows. The profile and advertisement must still be the selected request.
    func retryLocaleCatalog() {
        guard let request = localeCatalogRequest,
              request.profileID == selectedProfile.id,
              localeCatalog == nil,
              let failure = localeCatalogFailure,
              failure.isRetryable
        else {
            return
        }
        startLocaleCatalogLoad(request, profile: selectedProfile)
    }

    func retryLocaleCatalog(
        for gameID: GameID,
        retry: BasicChoiceCatalogRetryPresentation
    ) {
        guard let presentation = basicChoicePresentation(for: gameID),
              presentation.catalogRetry == retry,
              retry.profileID == selectedProfile.id,
              retry.catalogGeneration == localeCatalogGeneration
        else {
            return
        }
        retryLocaleCatalog()
    }

    func catalogRetryPresentation(
        storyResolution: StoryResolution?,
        promptKey: BasicChoicePromptKey
    ) -> BasicChoiceCatalogRetryPresentation? {
        guard case let .unavailable(.catalog(failure)) = storyResolution,
              localeCatalog == nil,
              !isLocaleCatalogLoading,
              let request = localeCatalogRequest,
              request.profileID == selectedProfile.id,
              localeCatalogFailure == failure,
              failure.isRetryable
        else {
            return nil
        }
        return BasicChoiceCatalogRetryPresentation(
            profileID: request.profileID,
            catalogGeneration: localeCatalogGeneration,
            promptKey: promptKey
        )
    }

    private func startLocaleCatalogLoad(
        _ request: LocaleCatalogRequest, profile: ServerProfile
    ) {
        localeCatalogTask?.cancel()
        localeCatalogGeneration += 1
        let catalogGeneration = localeCatalogGeneration
        localeCatalog = nil
        localeCatalogFailure = nil
        isLocaleCatalogLoading = true
        let loader = localeCatalogLoader
        let languages = preferredLanguagesProvider.preferredLanguages
        localeCatalogTask = Task { [weak self] in
            let result = await loader.load(
                advertisement: request.advertisement,
                profile: profile,
                preferredLanguages: languages
            )
            self?.applyLocaleCatalogResult(
                result, request: request, catalogGeneration: catalogGeneration
            )
        }
    }

    /// Publishes a completed load, but only when it is still the current one.
    ///
    /// Publication is a single assignment of an already-complete immutable snapshot, so a
    /// reader either sees the previous revision in full or the new one in full. There is no
    /// intermediate state in which a title could resolve from one revision and a body from
    /// another.
    func applyLocaleCatalogResult(
        _ result: Result<LocaleCatalogSnapshot, LocaleCatalogFailure>,
        request: LocaleCatalogRequest,
        catalogGeneration: Int
    ) {
        guard catalogGeneration == localeCatalogGeneration,
              localeCatalogRequest == request,
              !Task.isCancelled
        else { return }
        isLocaleCatalogLoading = false
        switch result {
        case let .success(snapshot):
            localeCatalog = snapshot
            localeCatalogFailure = nil
        case let .failure(failure):
            localeCatalog = nil
            localeCatalogFailure = failure
        }
    }

    /// Cancels any in-flight load and drops the published catalog.
    ///
    /// Called from ``AppModel/restartFlow(for:generation:)`` — the single choke point every
    /// profile switch, retry, and in-place endpoint edit already goes through — so a catalog
    /// verified against one server is never reachable while another server's flow is running.
    /// `failure` records why, so the presentation announces "still loading" and "no catalog"
    /// differently rather than conflating them.
    func invalidateLocaleCatalog(failure: LocaleCatalogFailure? = nil) {
        localeCatalogTask?.cancel()
        localeCatalogTask = nil
        localeCatalogRequest = nil
        localeCatalogGeneration += 1
        localeCatalog = nil
        localeCatalogFailure = failure
        isLocaleCatalogLoading = false
    }

    /// The catalog resolver for the currently selected profile, or `nil` when none is usable.
    ///
    /// Re-checks the binding rather than trusting that invalidation always ran: the published
    /// snapshot is only offered when its own request is still the current one *and* that
    /// request belongs to the currently selected profile. A stale snapshot that somehow
    /// survived a switch therefore still cannot be read.
    var localeCatalogResolver: LocaleCatalogResolver? {
        guard let snapshot = localeCatalog,
              let request = localeCatalogRequest,
              request.profileID == selectedProfile.id,
              request.advertisement.catalogRevision == snapshot.identity.catalogRevision,
              request.advertisement.manifestSha256 == snapshot.identity.manifestSha256
        else { return nil }
        return LocaleCatalogResolver(snapshot: snapshot)
    }

    /// Why no resolver is available, for a presentation that must say so rather than fail
    /// silently. `nil` means a resolver *is* available.
    var localeCatalogUnavailability: StoryUnavailableReason? {
        if localeCatalogResolver != nil {
            return nil
        }
        if let failure = localeCatalogFailure {
            return .catalog(failure)
        }
        if isLocaleCatalogLoading || localeCatalogRequest != nil {
            return .loading
        }
        return .catalog(.notAdvertised)
    }

    /// Resolves one `Read` question's whole story against the current catalog.
    ///
    /// Deliberately resolves title *and* body as one value: the title and every body entry
    /// come from the same snapshot in the same call, so a revision that changes between two
    /// reads can replace the whole story but can never split it.
    func storyResolution(for story: ReadStoryContent?) -> StoryResolution? {
        guard let story else { return nil }
        return StoryNarrativeLocalization.resolve(
            story.flavorText,
            resolver: localeCatalogResolver,
            catalogUnavailability: localeCatalogUnavailability
        )
    }
}
