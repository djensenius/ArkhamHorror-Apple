@testable import ArkhamHorrorShared
import Foundation
import Testing

enum DeckChoiceValidationSource: String, CaseIterable, Sendable {
    case synced
    case cached
    case cachedResolved
    case fallback
}

enum DeckChoiceValidationFailureKind: String, CaseIterable, Sendable {
    case unsupportedCard
    case transport
    case unknownTransport
    case timeout

    var message: String {
        switch self {
        case .unsupportedCard:
            "Unsupported card c99999"
        case .transport:
            "The server could not be reached. Check your connection and try again."
        case .unknownTransport, .timeout:
            "Deck validation failed. Try again."
        }
    }

    func enqueue(on service: ScriptedDeckService) async throws {
        switch self {
        case .unsupportedCard:
            let errors = try DeckValidationErrors([.unimplementedCard(CardCode("c99999"))])
            await service.enqueueValidate(.failure(DeckServiceError.validationFailed(errors)))
        case .transport:
            await service.enqueueValidate(.failure(DeckServiceError.transportFailure("offline")))
        case .unknownTransport:
            await service.enqueueValidate(.failure(TestFailure()))
        case .timeout:
            await service.setValidationDelay(.seconds(1))
            await service.enqueueValidate(.success(DeckValidationSuccess()))
        }
    }
}

@MainActor
func validatedDeckChoicePicker(
    deck: Deck,
    model: AppModel,
    service: ScriptedDeckService
) async -> LobbyDeckSelectionViewModel {
    await service.enqueueList(.success([deck]))
    await service.enqueueValidate(.success(DeckValidationSuccess()))
    let picker = LobbyDeckSelectionViewModel(
        profile: .hosted,
        deckService: service,
        tokenProvider: { try await model.currentDeckRequestContext(for: .hosted) }
    )
    await picker.load()
    #expect(picker.validationState(for: deck) == .valid)
    return picker
}

struct DeckChoiceValidationDecks {
    let original: Deck
    let selected: Deck
    let resolved: Deck
}

@MainActor
func prepareInvalidResolvedDeckChoice(
    model: AppModel,
    service: ScriptedDeckService,
    source: DeckChoiceValidationSource,
    failure: DeckChoiceValidationFailureKind
) async throws -> DeckChoiceValidationDecks {
    let original = try deckSyncChoiceSampleDeck()
    let picker = await validatedDeckChoicePicker(deck: original, model: model, service: service)
    var slots = original.playableList.slots.quantities
    try slots[CardCode("c99999")] = 1
    let resolved = deckSyncChoiceModifiedDeck(
        original,
        url: original.url,
        name: "New unsupported card",
        slots: CardQuantityMap(slots)
    )
    #expect(original.playableList != resolved.playableList)
    if source == .synced {
        await service.enqueueSync(.success(resolved), for: original.id)
    } else {
        let syncedAt = source == .fallback ? Date().addingTimeInterval(-600) : Date()
        await model.deckSyncTracker.recordSync(resolved, on: .hosted, at: syncedAt)
        model.recordSyncedDeckForChoice(resolved, on: .hosted)
        if source == .fallback {
            await service.enqueueSync(.failure(DeckServiceError.transportFailure("offline")))
        }
    }
    // This mirrors the views: an ID-cached .valid state can coexist with a
    // different displayed/clicked cached list.
    #expect(picker.validationState(for: resolved) == .valid)
    try await failure.enqueue(on: service)
    return DeckChoiceValidationDecks(
        original: original,
        selected: source == .cachedResolved ? resolved : original,
        resolved: resolved
    )
}

@MainActor
func expectResolvedDeckWasValidated(
    _ resolved: Deck,
    original: Deck,
    service: ScriptedDeckService,
    source: DeckChoiceValidationSource
) async {
    #expect(await service.validatedDeckLists == [
        DeckListInput(original.playableList), DeckListInput(resolved.playableList),
    ])
    let expectedSyncIDs = source == .synced || source == .fallback ? [original.id] : []
    #expect(await service.syncedIDs == expectedSyncIDs)
}
