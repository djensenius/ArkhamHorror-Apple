@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension AppModelLiveChooseDeckTests {
    private func liveChooseDeckViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ArkhamHorrorShared")
            .appendingPathComponent("Presentation")
            .appendingPathComponent("Decks")
            .appendingPathComponent("LiveChooseDeckSelectionView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test("Live deck picker enablement is delegated to the model presentation rule")
    func liveChooseDeckViewUsesModelPickerEnabledRule() throws {
        let source = try liveChooseDeckViewSource()

        #expect(source.contains("let pickerEnabled = model.liveChooseDeckPickerEnabled("))
        #expect(source.contains(".disabled(!pickerEnabled)"))
        #expect(!source.contains(".disabled(isSubmitting"))
    }

    @Test("Live deck picker presentation requires valid deck validation")
    func liveChooseDeckPickerEnabledRequiresValidDeckValidation() async throws {
        let context = try await makeDeckPresentationContext()

        #expect(context.model.liveChooseDeckPickerEnabled(
            for: context.gameID,
            promptKey: context.promptKey,
            validation: .valid
        ))
        #expect(!context.model.liveChooseDeckPickerEnabled(
            for: context.gameID,
            promptKey: context.promptKey,
            validation: .pending
        ))
        #expect(!context.model.liveChooseDeckPickerEnabled(
            for: context.gameID,
            promptKey: context.promptKey,
            validation: .invalid("invalid")
        ))
        #expect(!context.model.liveChooseDeckPickerEnabled(
            for: context.gameID,
            promptKey: context.promptKey,
            validation: .failed("failed")
        ))
    }

    @Test("Live deck picker presentation locks while a deck answer is pending")
    func liveChooseDeckPickerEnabledLocksForPendingDeckAnswer() async throws {
        let context = try await makeDeckPresentationContext()

        for phase in [
            BasicChoiceActionPhase.sending,
            .awaitingSnapshot,
            .uncertain,
        ] {
            context.model.basicChoiceActions[context.gameID] = BasicChoiceActionRecord(
                identity: context.prompt.identity,
                submission: .deck(context.deck.id),
                attemptID: UUID(),
                connectionID: context.installed.connectionID,
                phase: phase
            )
            #expect(!context.model.liveChooseDeckPickerEnabled(
                for: context.gameID,
                promptKey: context.promptKey,
                validation: .valid
            ))
        }

        context.model.basicChoiceActions[context.gameID] = BasicChoiceActionRecord(
            identity: context.prompt.identity,
            submission: .deck(context.deck.id),
            attemptID: UUID(),
            connectionID: context.installed.connectionID,
            phase: .retryable(.transportFailure)
        )
        #expect(context.model.liveChooseDeckPickerEnabled(
            for: context.gameID,
            promptKey: context.promptKey,
            validation: .valid
        ))
    }

    @Test("Cancelled live deck send after handoff is uncertain")
    func cancelledLiveDeckSendAfterHandoffIsUncertain() async throws {
        let context = try await makeDeckPresentationContext()
        await context.installed.connection.enqueueSendResult(.failure(CancellationError()))

        #expect(await !context.model.chooseDeckForLivePrompt(context.deck, in: context.gameID))
        #expect(await context.installed.connection.sentData.count == 1)
        #expect(context.model.basicChoiceActions[context.gameID]?.phase == .uncertain)
        #expect(context.model.liveChooseDeckIsAwaitingAnswer(
            for: context.gameID,
            promptKey: context.promptKey
        ))
        #expect(!context.model.liveChooseDeckPickerEnabled(
            for: context.gameID,
            promptKey: context.promptKey,
            validation: .valid
        ))
    }

    private func makeDeckPresentationContext() async throws -> LiveChooseDeckPresentationContext {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        return LiveChooseDeckPresentationContext(
            model: model,
            gameID: gameID,
            deck: deck,
            installed: installed,
            prompt: prompt,
            promptKey: prompt.identity.promptKey
        )
    }
}

private struct LiveChooseDeckPresentationContext {
    let model: AppModel
    let gameID: GameID
    let deck: Deck
    let installed: InstalledLiveChooseDeckPrompt
    let prompt: BasicChoicePromptPresentation
    let promptKey: BasicChoicePromptKey
}
