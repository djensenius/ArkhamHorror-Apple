@testable import ArkhamHorrorShared
import Foundation
import Testing

/// AppModel-level coverage proving `reconcileBasicChoice` retires a `.retryable` action
/// record whose originally-targeted choice has stopped being actionable against a fresh
/// authoritative projection -- so one location disappearing from a
/// `TargetLabel(LocationTarget)` prompt (for example, the location itself leaving play)
/// can never permanently block every other, still-actionable sibling choice for the exact
/// same prompt (issue djensenius/ArkhamHorror-Apple#35, independent-review blocker 2 on
/// PR #36). Shares `AppModelReadLocationTests.swift`'s `snapshotUpdate`/
/// `loadContractFixtureValue` helpers and `AppModelBasicChoiceTests.swift`'s
/// `makeModern`/`startChoiceSession` via `AppModelLiveGameTests`.
extension AppModelLiveGameTests {
    /// Pushes a same-version resend of the real 3-location
    /// `question-choose-one-location-multiple.json` fixture with locations 398/39a
    /// always present and 399 present only when `includingSecondLocation` -- letting a
    /// test model location 399 disappearing/reappearing from the authoritative
    /// `locations` map while the raw question itself stays byte-identical.
    private func pushLocationTripleSnapshot(
        connection: FakeGameSocketConnection,
        envelope: GetGameEnvelope,
        locationQuestion: JSONValue,
        includingSecondLocation: Bool
    ) async throws {
        var locationIDs = [
            "00000000-0000-0000-0000-000000000398",
            "00000000-0000-0000-0000-00000000039a",
        ]
        if includingSecondLocation {
            locationIDs.insert("00000000-0000-0000-0000-000000000399", at: 1)
        }
        let update = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: locationQuestion,
            addingLocationIDs: locationIDs
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
    }

    @Test("A retryable location choice clears when its target disappears; sibling sends once")
    func retryableLocationChoiceClearsWhenTargetDisappears() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        // A transport failure sending location 399 (index 1) leaves the record
        // `.retryable(.transportFailure)`.
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .retryableFailure)
        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase == .retryable(.transportFailure)
        )

        // The exact same prompt/version is observed again (`samePrompt` still holds --
        // the original send provably never landed), but location 399 has meanwhile left
        // the authoritative `locations` map entirely while the raw question itself is
        // byte-identical.
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: false
        )

        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(model.basicChoiceActions[gameID] == nil)

        // The retired record no longer stands in the way of a still-actionable sibling
        // (index 0, location 398).
        await connection.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData.count == 2)
    }

    @Test("Two scenes racing the newly-freed sibling after reconciliation still send exactly once")
    func racingSiblingAfterReconciliationSendsOnce() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .retryableFailure)

        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: false
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(model.basicChoiceActions[gameID] == nil)

        // Two independent callers (simulating two scenes sharing the same process-global
        // model) both race to claim the now-actionable sibling (index 0) the instant the
        // record is retired -- exactly one may claim and send it.
        await connection.setSendGated(true)
        let first = Task { await model.submitBasicChoice(current.identity, choiceIndex: 0) }
        await connection.waitUntilSendPending(1)
        let second = await model.submitBasicChoice(current.identity, choiceIndex: 0)
        #expect(second == .alreadyPending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(await connection.sentData.count == 2)
    }

    @Test("A retryable record survives unrelated resends, clearing once its target disappears")
    func retryableRecordSurvivesUntilTargetActuallyDisappears() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .retryableFailure)

        // "Reappears" while still retryable: an identical-content resend of the exact
        // same snapshot (target 399 still present) must leave the record untouched.
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase
                == .retryable(.transportFailure)
        )
        #expect(model.basicChoicePresentation(for: gameID)?.canRetry == true)
        #expect(model.basicChoiceActions[gameID]?.choiceIndex == 1)

        // Only now does the target actually leave the authoritative projection.
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: false
        )
        #expect(model.basicChoiceActions[gameID] == nil)

        // "Reappears" again after reconciliation already retired the record: the target
        // returning in yet another same-version resend must not resurrect a claim, and
        // the choice remains cleanly submittable from scratch.
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        #expect(model.basicChoiceActions[gameID] == nil)
        let revived = try #require(model.basicChoicePresentation(for: gameID))
        #expect(revived.canSubmit)
        await connection.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(revived.identity, choiceIndex: 1)
                == .sentAwaitingSnapshot
        )
    }

    @Test("With no authoritative snapshot, a retryable record stays blocked, never auto-cleared")
    func noAuthoritativeSnapshotLeavesRecordBlocked() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .retryableFailure)

        // No further snapshot of any kind ever arrives -- reconciliation never runs, so
        // the record cannot spontaneously clear on its own; a sibling remains blocked.
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .alreadyPending)
        #expect(model.basicChoiceActions[gameID]?.choiceIndex == 1)
        #expect(await connection.sentData.count == 1)
    }

    @Test("A non-location retryable choice is unaffected by reconciliation on identical resend")
    func nonLocationRetryableChoiceUnaffectedByReconciliation() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        // The base envelope's own `ChooseOne` question offers only ordinary
        // `ComponentLabel`/`EndTurnButton`/`AbilityLabel` choices, none carrying a
        // `LocationTarget` -- `isChoiceActionable` returns `true` unconditionally for
        // these once wire-supported (`BoardProjection.swift`), so no projection change
        // can ever make one newly non-actionable.
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .retryableFailure)

        let ownerID = try #require(envelope.playerID)
        let sameQuestion = try #require(envelope.game.question[ownerID]?.rawValue)
        let resend = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps,
            replacingQuestionWith: sameQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(resend))))
        await connection.waitUntilAwaitingNextEvent()

        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase
                == .retryable(.transportFailure)
        )
        #expect(model.basicChoiceActions[gameID]?.choiceIndex == 1)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .alreadyPending)

        await connection.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(identity) == .sentAwaitingSnapshot)
        #expect(await connection.sentData.count == 2)
    }

    @Test("A resolvable Read continue's retryable record survives an identical resend")
    func retryableContinueReadingRecordSurvivesIdenticalResend() async throws {
        // Unlike a location target (tracked in the separate, mutable `locations` map),
        // a `.continueReading` choice's actionability is a pure function of its own
        // embedded flavor text (`StoryNarrativeLocalization`, a static, compiled-in
        // vocabulary) -- so it can never flip while `samePrompt` holds, since any change
        // to the story's own content changes the raw question bytes, which already
        // clears the record via the pre-existing, unconditional `!samePrompt` branch.
        // This proves the shared retirement check consults the *current* question's
        // `story` uniformly for every kind, without ever misreading a resolvable Read
        // prompt as having lost its target.
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let readQuestion = try loadContractFixtureValue("question-read-with-cards")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .retryableFailure)

        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase
                == .retryable(.transportFailure)
        )
        #expect(model.basicChoiceActions[gameID] != nil)

        await connection.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(identity) == .sentAwaitingSnapshot)
    }

    @Test("A pending, not yet retryable, choice's disappearing target blocks a competing send")
    func pendingNotRetryableDisappearanceDoesNotPermitCompetingSend() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: true
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let inFlight = Task { await model.submitBasicChoice(identity, choiceIndex: 1) }
        await connection.waitUntilSendPending(1)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)

        // The target (location 399) disappears from the authoritative projection while
        // the send for it is still genuinely in flight (phase `.sending`, not yet
        // `.retryable`). The receive loop (a task independent of `inFlight`'s still-gated
        // send) fully processes this same-version snapshot -- proven by
        // `waitUntilAwaitingNextEvent()` inside the helper -- while the send is still
        // suspended: retiring the record here could let a second choice be claimed and
        // sent before this first one's outcome is known, risking two accepted answers,
        // so it must be left completely untouched.
        try await pushLocationTripleSnapshot(
            connection: connection, envelope: envelope, locationQuestion: locationQuestion,
            includingSecondLocation: false
        )

        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
        #expect(model.basicChoiceActions[gameID]?.choiceIndex == 1)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .alreadyPending)

        await connection.resumeOldestSend(with: .success(()))
        #expect(await inFlight.value == .sentAwaitingSnapshot)
        #expect(await connection.sentData.count == 1)
    }
}
