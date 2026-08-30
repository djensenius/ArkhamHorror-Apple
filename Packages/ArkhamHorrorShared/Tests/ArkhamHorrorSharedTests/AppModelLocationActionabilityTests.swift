@testable import ArkhamHorrorShared
import Foundation
import Testing

/// AppModel-level coverage proving ``BoardProjection/isChoiceActionable(_:story:)``'s
/// presentation/action-authority gate -- for both `.chooseLocation` choices (issue
/// djensenius/ArkhamHorror-Apple#35, independent-review blocker 3) and `.continueReading`
/// choices whose story this client cannot lawfully resolve (blocker 2) -- is revalidated
/// fresh against the current authoritative projection immediately before send -- never the
/// projection captured whenever a choice was last rendered -- and that no caller can ever
/// bypass it, whether by racing a same-version snapshot replacement or by attempting the
/// same not-yet-actionable choice concurrently from more than one place. Split out of
/// `AppModelReadLocationTests.swift` to keep both files under the repository's
/// `file_length` lint limit; shares that file's `snapshotUpdate`/`loadContractFixtureValue`
/// helpers via `AppModelLiveGameTests`.
extension AppModelLiveGameTests {
    // swiftlint:disable line_length
    @Test(
        "A location choice that becomes unavailable after render is rejected and never sent, even though it parsed as fully wire-supported"
    )
    // swiftlint:enable line_length
    func locationBecomingUnavailableBeforeTapCannotBeSent() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        let allLocationsKnown = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: locationQuestion,
            addingLocationIDs: [
                "00000000-0000-0000-0000-000000000398",
                "00000000-0000-0000-0000-000000000399",
                "00000000-0000-0000-0000-00000000039a",
            ]
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(allLocationsKnown))))
        await connection.waitUntilAwaitingNextEvent()
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        // A same-version, different-content authoritative snapshot -- for example the
        // location's own removal from play -- withdraws location 399 from the projection
        // without changing the prompt/question identity at all. The exact same prompt
        // identity/choice index that was actionable a moment ago must revalidate against
        // *this* projection immediately before send, never the one it was originally
        // rendered against.
        let oneLocationWithdrawn = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: locationQuestion,
            addingLocationIDs: [
                "00000000-0000-0000-0000-000000000398",
                "00000000-0000-0000-0000-00000000039a",
            ]
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(oneLocationWithdrawn))))
        await connection.waitUntilAwaitingNextEvent()

        // The stale-rendered choice at index 1 (location 399) can never be claimed/sent
        // once its target is no longer authoritatively known, even though its identity
        // (game/owner/version/rawQuestion) is still the exact one still being answered.
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .unsupportedChoice)
        #expect(await connection.sentData.isEmpty)
        #expect(model.basicChoiceActions[gameID] == nil)

        // A sibling choice (index 2, location 39a) whose target is still known remains
        // fully actionable through the exact same identity/session.
        await connection.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 2) == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData.count == 1)
    }

    // swiftlint:disable line_length
    @Test(
        "Concurrent submissions of the same now-unavailable location choice from two callers both fail closed -- never a cross-scene bypass of the actionability gate"
    )
    // swiftlint:enable line_length
    func concurrentSubmissionsOfUnavailableLocationNeverBypassGate() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        // Only locations 398/39a are authoritatively known -- choice index 1 (location
        // 399) is wire-supported but never actionable throughout this test.
        let update = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: locationQuestion,
            addingLocationIDs: [
                "00000000-0000-0000-0000-000000000398",
                "00000000-0000-0000-0000-00000000039a",
            ]
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        // Two independent callers (simulating two scenes observing the same
        // process-global model) submit the exact same not-yet-actionable choice
        // concurrently -- both must fail closed, and neither may sneak a send through
        // ahead of the other.
        async let first = model.submitBasicChoice(identity, choiceIndex: 1)
        async let second = model.submitBasicChoice(identity, choiceIndex: 1)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 == .unsupportedChoice })
        #expect(await connection.sentData.isEmpty)
        #expect(model.basicChoiceActions[gameID] == nil)
    }

    // swiftlint:disable line_length
    @Test(
        "The real production question-read.json Continue choice cannot be submitted -- it fails closed rather than silently broadening to actionable"
    )
    // swiftlint:enable line_length
    func realUnresolvableReadStoryCannotBeSubmitted() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        // The real, currently-vendored `question-read.json`: none of its 4 real dotted
        // i18n keys are in `StoryNarrativeLocalization.chromeVocabulary` (see
        // `StoryNarrativeLocalizationTests.realReadFixtureFailsClosed`), so this client
        // cannot lawfully resolve its narrative -- the honest, fail-closed outcome per
        // this project's own localization licensing constraints.
        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        let presentation = try #require(model.basicChoicePresentation(for: gameID))

        // The prompt itself remains visible and generally submittable (not
        // `.updateRequired` -- the question decoded successfully) -- only this specific
        // choice's story-content resolution gates it, exactly mirroring an unavailable
        // `.chooseLocation` target rather than a parse failure.
        #expect(presentation.readOnlyReason == nil)
        #expect(presentation.question.supportedQuestion?.kind == .read)

        #expect(
            await model.submitBasicChoice(presentation.identity, choiceIndex: 0)
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
        #expect(model.basicChoiceActions[gameID] == nil)
    }
}
