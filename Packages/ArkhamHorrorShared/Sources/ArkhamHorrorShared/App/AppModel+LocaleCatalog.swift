import Foundation

// swiftlint:disable file_length

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

    /// Retries the failed catalog or image dependency without restarting the session.
    /// An already-verified catalog is never discarded for an image-only failure.
    func retryLocaleCatalog() {
        guard let request = localeCatalogRequest,
              request.profileID == selectedProfile.id,
              !isLocaleCatalogLoading,
              localeCatalogRetryReason != nil
        else {
            return
        }
        if localeCatalogFailure == nil, localeCatalog != nil {
            retryStoryAssetSource(request, profile: selectedProfile)
        } else {
            startLocaleCatalogLoad(request, profile: selectedProfile)
        }
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
        localizationReasons: [StoryUnavailableReason],
        promptKey: BasicChoicePromptKey
    ) -> BasicChoiceCatalogRetryPresentation? {
        guard let reason = localeCatalogRetryReason,
              localizationReasons.contains(reason),
              !isLocaleCatalogLoading,
              let request = localeCatalogRequest,
              request.profileID == selectedProfile.id
        else {
            return nil
        }
        return BasicChoiceCatalogRetryPresentation(
            profileID: request.profileID,
            catalogGeneration: localeCatalogGeneration,
            promptKey: promptKey,
            scope: reason == .imagePipelineUnavailable ? .localImagePipeline
                : (localeCatalogFailure == nil ? .images : .catalog)
        )
    }

    private func startLocaleCatalogLoad(
        _ request: LocaleCatalogRequest, profile: ServerProfile
    ) {
        localeCatalogTask?.cancel()
        localeCatalogGeneration += 1
        let catalogGeneration = localeCatalogGeneration
        localeCatalog = nil
        storyAssetSource = nil
        storyAssetSourceFailure = nil
        localeCatalogFailure = nil
        isLocaleCatalogLoading = true
        let loader = localeCatalogLoader
        let sourceLoader = storyAssetSourceLoader
        let hasImagePipeline = prepareStoryAssetCache()
        let languages = preferredLanguagesProvider.preferredLanguages
        localeCatalogTask = Task { [weak self] in
            async let catalogResult = loader.load(
                advertisement: request.advertisement,
                profile: profile,
                preferredLanguages: languages
            )
            var source: AssetSourceNamespace?
            var sourceFailure: LocaleCatalogFailure?
            do {
                source = try await hasImagePipeline ? sourceLoader.load(for: profile) : nil
            } catch is CancellationError {
                return
            } catch {
                sourceFailure = (error as? LocaleCatalogFailure) ?? .transportFailure
            }
            let result = await catalogResult
            self?.applyLocaleCatalogResult(
                result, request: request, catalogGeneration: catalogGeneration,
                assetSource: source, assetSourceFailure: sourceFailure
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
        catalogGeneration: Int,
        assetSource: AssetSourceNamespace? = nil,
        assetSourceFailure: LocaleCatalogFailure? = nil
    ) {
        guard catalogGeneration == localeCatalogGeneration,
              localeCatalogRequest == request,
              !Task.isCancelled
        else { return }
        isLocaleCatalogLoading = false
        switch result {
        case let .success(snapshot):
            localeCatalog = snapshot
            storyAssetSource = assetCacheService == nil ? nil : assetSource
            storyAssetSourceFailure = assetSourceFailure
            localeCatalogFailure = nil
        case let .failure(failure):
            localeCatalog = nil
            storyAssetSource = nil
            storyAssetSourceFailure = nil
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
        storyAssetSource = nil
        storyAssetSourceFailure = nil
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
        return LocaleCatalogResolver(
            snapshot: snapshot, assetSource: assetCacheService == nil ? nil : storyAssetSource,
            assetUnavailability: storyAssetUnavailability
        )
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

    func storyResolution(
        for flavorText: QuestionPresentation.FlavorText?
    ) -> StoryResolution? {
        guard let flavorText else { return nil }
        guard let converted = presentationFlavorText(flavorText) else {
            return .unavailable(.unsupportedEntry)
        }
        return StoryNarrativeLocalization.resolve(
            converted,
            resolver: localeCatalogResolver,
            catalogUnavailability: localeCatalogUnavailability
        )
    }

    private func presentationFlavorText(
        _ flavorText: QuestionPresentation.FlavorText
    ) -> FlavorText? {
        var body: [FlavorTextEntry] = []
        body.reserveCapacity(flavorText.body.count)
        for entry in flavorText.body {
            guard let converted = presentationFlavorEntry(entry) else { return nil }
            body.append(converted)
        }
        return FlavorText(title: flavorText.title, body: body)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func presentationFlavorEntry(_ entry: JSONValue) -> FlavorTextEntry? {
        guard case let .object(object) = entry,
              case let .string(tag)? = object["tag"]
        else { return nil }
        switch tag {
        case "BasicEntry":
            guard case let .string(text)? = object["text"] else { return nil }
            return .basic(text: text)
        case "HeaderEntry":
            guard case let .number(levelNumber)? = object["level"],
                  let magnitude = levelNumber.wholeNumberMagnitude,
                  let parsedMagnitude = Int(magnitude),
                  case let .string(key)? = object["key"]
            else { return nil }
            let integerLevel = levelNumber.sign == .minus ? -parsedMagnitude : parsedMagnitude
            return .header(level: FlavorTextHeadingLevel(rawValue: integerLevel), key: key)
        case "I18nEntry":
            guard case let .string(key)? = object["key"],
                  case let .object(variables)? = object["variables"]
            else { return nil }
            return .i18n(key: key, variables: .object(variables))
        case "ModifyEntry":
            guard case let .array(rawModifiers)? = object["modifiers"],
                  let rawEntry = object["entry"],
                  let converted = presentationFlavorEntry(rawEntry)
            else { return nil }
            var modifiers: [FlavorTextModifier] = []
            for rawModifier in rawModifiers {
                guard case let .string(text) = rawModifier,
                      let modifier = FlavorTextModifier(rawValue: text)
                else { return nil }
                modifiers.append(modifier)
            }
            return .modify(modifiers: modifiers, entry: converted)
        case "CompositeEntry":
            guard let entries = presentationFlavorEntries(object["entries"]) else { return nil }
            return .composite(entries: entries)
        case "ColumnEntry":
            guard let entries = presentationFlavorEntries(object["entries"]) else { return nil }
            return .column(entries: entries)
        case "ListEntry":
            guard case let .array(rawItems)? = object["list"] else { return nil }
            var items: [FlavorTextListItem] = []
            for rawItem in rawItems {
                guard let item = presentationFlavorListItem(rawItem) else { return nil }
                items.append(item)
            }
            return .list(items: items)
        case "CardEntry":
            guard case let .string(rawCardCode)? = object["cardCode"],
                  let cardCode = BasicChoiceParser.strictCardCode(rawCardCode),
                  case let .array(rawModifiers)? = object["imageModifiers"]
            else { return nil }
            var modifiers: [FlavorTextImageModifier] = []
            for rawModifier in rawModifiers {
                guard case let .string(text) = rawModifier,
                      let modifier = FlavorTextImageModifier(rawValue: text)
                else { return nil }
                modifiers.append(modifier)
            }
            return .card(cardCode: cardCode, imageModifiers: modifiers)
        case "TarotEntry":
            guard case let .string(arcana)? = object["tarot"] else { return nil }
            return .tarot(arcana: arcana)
        case "ChaosTokenEntry":
            guard case let .string(face)? = object["chaosTokenFace"] else { return nil }
            return .chaosToken(face: ChaosTokenFace(face))
        case "ChaosTokenMorphEntry":
            guard case let .string(from)? = object["morphFrom"],
                  case let .string(target)? = object["morphTo"]
            else { return nil }
            return .chaosTokenMorph(from: ChaosTokenFace(from), target: ChaosTokenFace(target))
        case "EntrySplit":
            return .split
        default:
            return nil
        }
    }

    private func presentationFlavorEntries(_ value: JSONValue?) -> [FlavorTextEntry]? {
        guard case let .array(rawEntries)? = value else { return nil }
        var entries: [FlavorTextEntry] = []
        entries.reserveCapacity(rawEntries.count)
        for rawEntry in rawEntries {
            guard let entry = presentationFlavorEntry(rawEntry) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    private func presentationFlavorListItem(_ item: JSONValue) -> FlavorTextListItem? {
        guard case let .object(object) = item,
              let entryValue = object["entry"],
              let entry = presentationFlavorEntry(entryValue),
              case let .array(rawNested)? = object["nested"]
        else { return nil }
        var nested: [FlavorTextListItem] = []
        for raw in rawNested {
            guard let child = presentationFlavorListItem(raw) else { return nil }
            nested.append(child)
        }
        return FlavorTextListItem(entry: entry, nested: nested)
    }

    func choiceFlavorResolutions(
        for semanticPresentation: BoundQuestionPresentation?
    ) -> [Int: StoryResolution] {
        guard let semanticPresentation else { return [:] }
        var result: [Int: StoryResolution] = [:]
        for choice in semanticPresentation.presentation.choices {
            if let resolution = storyResolution(for: choice.flavorText) {
                result[choice.sourceIndex] = resolution
            }
        }
        return result
    }

    func promptLabelResolutions(
        for presentation: QuestionPresentation?
    ) -> [String: BasicChoiceLabelResolution] {
        guard let presentation else { return [:] }
        let promptLabels: [(key: String, label: QuestionPresentation.Label?)] = [
            ("label", presentation.label),
            ("questionLabel", presentation.questionLabel),
            ("completionLabel", presentation.completionLabel),
            ("confirmLabel", presentation.confirmLabel),
            ("backLabel", presentation.backLabel),
        ]
        let amountLabels: [(key: String, wireLabel: String)] =
            (presentation.amountChoices ?? []).map { choice in
                (
                    key: "amountChoice.\(choice.choiceID)",
                    wireLabel: choice.label
                )
            }
        let paymentLabels: [(key: String, label: QuestionPresentation.Label)] =
            (presentation.paymentChoices ?? []).map { choice in
                (
                    key: "paymentChoice.\(choice.choiceID)",
                    label: choice.title
                )
            }
        return labelResolutions(
            promptLabels.compactMap { key, label in
                label.map { (key: key, wireLabel: $0.text) }
            } + amountLabels + paymentLabels.map { key, label in
                (key: key, wireLabel: label.text)
            }
        )
    }

    /// Resolves every deployment-owned choice label against one current catalog snapshot,
    /// retaining authoritative source indices so unresolved entries stay visible in place.
    func choiceLabelResolutions(
        for question: BasicChoiceQuestion?,
        semanticPresentation: BoundQuestionPresentation? = nil
    ) -> [Int: BasicChoiceLabelResolution] {
        let labels: [(key: Int, wireLabel: String)] = if let semanticPresentation {
            semanticPresentation.presentation.choices.compactMap { choice in
                guard let label = choice.label, label.text.hasPrefix("$") else { return nil }
                return (key: choice.sourceIndex, wireLabel: label.text)
            }
        } else {
            (question?.choices ?? []).compactMap { choice in
                guard let localizationKey = choice.localizationKey else { return nil }
                return (key: choice.index, wireLabel: "$\(localizationKey)")
            }
        }
        return labelResolutions(labels)
    }

    private func labelResolutions<Key: Hashable>(
        _ labels: [(key: Key, wireLabel: String)]
    ) -> [Key: BasicChoiceLabelResolution] {
        let resolver = localeCatalogResolver
        let unavailability = localeCatalogUnavailability ?? .catalog(.notAdvertised)
        var result: [Key: BasicChoiceLabelResolution] = [:]
        for label in labels {
            switch StoryNarrativeLocalization.resolveProductionChoiceLabel(
                label.wireLabel,
                resolver: resolver,
                catalogUnavailability: unavailability
            ) {
            case let .success(value):
                result[label.key] = .resolved(value)
            case let .failure(reason):
                result[label.key] = .unavailable(reason)
            }
        }
        return result
    }
}
